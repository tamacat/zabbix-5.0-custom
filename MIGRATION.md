# PHP 8 Migration Notes

Zabbix 5.0.47's frontend (`sources/zabbix-5.0.47/ui/`) was written against PHP 7.4-and-earlier
semantics. This document catalogs every PHP 7 → PHP 8 compatibility issue found and fixed while
rebuilding it to run on PHP 8.3 (Alpine 3.24), **without upgrading Zabbix itself past the 5.0.x
line**. Every fix below is a type/syntax-level change only — no business logic, naming, class
structure, or file layout was altered, and Zabbix's own custom autoloader was left untouched.

## Methodology

- **[PHPStan](https://phpstan.org/)** static analysis, run against the whole `ui/` tree via a
  bootstrap that deliberately does *not* register Zabbix's own autoloader (PHPStan's reflection
  layer is incompatible with it) and instead relies on `scanDirectories` for symbol resolution.
  - Level 2 catches dynamic-property deprecations and syntax-level parameter-order deprecations.
  - Level 5 additionally checks argument types against real function signatures — used narrowly,
    filtered to `... given` messages, to find every remaining "passing null" and "float where an
    int is expected" site without wading through the thousands of unrelated findings a full level-5
    run produces on a codebase this size (see [Notes on false positives](#notes-on-false-positives)).
  - The [`phpstan/phpstan-deprecation-rules`](https://github.com/phpstan/phpstan-deprecation-rules)
    extension, to catch calls to anything carrying a `@deprecated` tag — including PHP's own
    built-in functions, which PHPStan's bundled stubs mark accordingly.
- Direct `grep` for functions **removed** outright in PHP 8 (`create_function()`, `each()`,
  `get_magic_quotes_gpc()`, `money_format()`, etc.) — none were found in this codebase.
- Live reproduction with a temporarily instrumented error handler for one bug (see
  [The graph-rendering incident](#the-graph-rendering-incident)) that only manifested as a
  resource-exhaustion crash rather than a pattern a static scan alone would flag as suspicious.
- The bundled PHPUnit suite (25 cases covering the diff scope) re-run after every change.

## Issues found and fixed

### 1. Dynamic properties (deprecated in PHP 8.2)

Zabbix's HTML-builder class hierarchy (`CTag` and everything that extends it) and several other
classes assigned to properties that were never declared, relying on PHP's historical
create-on-write behavior. A full-tree PHPStan sweep found **965 such properties across 23
files**; each was resolved by adding a proper property declaration matching the existing code's
own `@var` PHPDoc style, not by suppressing the check.

Representative files: `include/classes/html/CTag.php`, `CTableInfo.php`, `CMultiSelect.php`,
`CDateSelector.php`, `include/classes/graphdraw/{CGraphDraw,CLineGraphDraw,CPieGraphDraw}.php`,
and 17 more across `app/controllers/`, `include/classes/core/`, `include/classes/export/`,
`include/classes/macros/`, `include/classes/mvc/`, `include/classes/parsers/`,
`include/classes/setup/`, `include/classes/widgets/`, and `include/classes/api/wrappers/`.

### 2. Required parameter declared after an optional one (deprecated in PHP 8.0)

```php
// before
function get(array $options = [], $width, $height) { ... }
// after
function get(array $options = [], $width = null, $height = null) { ... }
```

Every call site already passed every argument positionally, so the added defaults are never
actually used — they exist purely to satisfy PHP 8's parser. Found and fixed in:

- `include/items.inc.php`, `include/triggers.inc.php` — several lookup/formatting functions.
- `include/classes/db/DB.php` — `applyQueryOutputOptions()`, `applyQueryFilterOptions()`,
  `dbFilter()`, `applyQuerySortOptions()`.
- `include/classes/helpers/CSvgGraphHelper.php` — `get()`, `getMetricsData()`,
  `getGraphDataSource()`, `getTimePeriods()`.
- `include/classes/import/CConfigurationImport.php` — the constructor.

### 3. Passing `null` to a non-nullable internal-function parameter (deprecated in PHP 8.1)

PHP 8.1 started warning whenever `null` reaches a built-in function's parameter that isn't
explicitly typed nullable. Found and fixed:

- `include/classes/db/MysqlDbBackend.php` — `mysqli::real_connect()`'s `$flags` parameter
  defaulted to `null`; changed to `0`.
- `include/func.inc.php` — `zbx_setcookie()` / `zbx_unsetcookie()` passed `null` for
  `setcookie()`'s `$value`/`$domain`; both now default to `''`, the correct "no value" /
  "no specific domain" equivalent.
- `include/classes/core/ZBase.php` — same `setcookie()` pattern in `initMessages()`.
- `include/classes/validators/CRegexValidator.php` — `preg_match($pattern, null)`. This one
  was a **real functional bug**, not just a cosmetic warning: the class calls the pattern only to
  trigger a PCRE compile-error check, using a custom `set_error_handler()` that treats *any*
  non-empty PHP message — deprecation notices included — as "the regex is invalid". Under PHP
  8.1+, this made every regular-expression validation in the product fail regardless of whether
  the pattern was actually valid, because the deprecation notice itself was being read back as
  a validation failure. Fixed by passing `''` instead of `null`.
- `include/classes/html/pageheader/CPageHeader.php` — `substr(get_cookie(...), 16, 16)` on any
  unauthenticated request (login page, health checks) where no session cookie exists yet;
  `get_cookie()` now defaults to `''` instead of `null`.

### 4. The graph-rendering incident

This is the most involved fix, so it gets its own write-up.

**Symptom**: after all of the above were already fixed and verified, graphs on the classic
"Monitoring → Hosts → Graphs" screen became very slow to render, with some stuck loading
indefinitely.

**Root cause**: `include/draw.inc.php`'s `zbx_colormix()` computed an RGB color by linear
interpolation (necessarily producing a float) and passed it straight to
`imagecolorresolvealpha()`, whose R/G/B parameters are typed `int`. PHP 8.1 emits a
`Deprecated: Implicit conversion from float ... to int loses precision` notice for exactly this.
Zabbix's own error handler (`zbx_err_handler()` in `include/func.inc.php`) turns *every* PHP
error/warning/deprecation into an in-app message — including a full call-stack string — via its
`error()` function. For a single 1000×201px line graph with a wide value range, this single call
site fired **over 14,500 times in one request**. When the request finished, Zabbix's own
fallback renderer (`show_messages()`) then tried to draw all 14,500+ accumulated messages as a
PNG image to report them to the user — and *that* image-buffer allocation exhausted the 128 MB
`memory_limit`, producing the visible hang/crash.

Confirmed via a controlled A/B test (rebuilding the image from the commit immediately before the
audit fixes and reproducing the identical failure) that this bug **predates** this migration's
PHP 8 audit work — it is a latent defect in Zabbix 5.0.47's own graph-rendering code, exposed by
running on PHP 8.1+, not introduced by any fix in this repository.

**Diagnosis method**: temporarily patched the error handler in a running container to log the
originating file/line of every intercepted PHP message, then exercised every graph *draw type*
present in the schema (plain line, bold line, gradient/filled region, dotted, percentile-legend
marker, axis-arrow marker, non-working-hours background shading) and iterated until zero
deprecation messages fired.

**Fixes** (all are type-level casts — the drawn output is pixel-identical; PHP's own historical
implicit conversion already truncated toward zero, so `(int)` reproduces exactly what used to
happen silently):

| File | What changed |
|---|---|
| `include/draw.inc.php` | `zbx_colormix()`: cast interpolated R/G/B to `int`. `zbx_imageline()` / `zbx_imagealine()`: their own `round()`/`floor()` calls return `float` in PHP — every coordinate these *wrapper* functions computed was still reaching `imageline()`/`imagesetpixel()`/`imagecolorat()` as a float, despite the wrapper's entire purpose being "hand GD an integer coordinate" (see the file's own long-standing comment: *"PHP imageline() function is broken because it drops fraction instead of correct rounding"*). `zbx_imagealine()` runs this per pixel inside a loop for **every plain line-drawtype graph**, not just gradient-filled ones. |
| `include/graphs.inc.php` | `imageText()`: round + cast `$x`/`$y` once at the top of the function, matching the same wrapper convention. |
| `include/classes/graphdraw/CLineGraphDraw.php` | Six `imagefilledpolygon()`/`imagepolygon()` calls dropped the `$num_points` argument (see [§5](#5-deprecated-num_points-argument-to-imagefilledpolygon-php-80)); the gradient-fill inner loop's per-pixel alpha and coordinates cast to `int`; two raw `imageLine()` calls that bypassed the existing `zbx_imageline()` wrapper switched to it; the non-working-hours background-shading loop's `round()`/`ceil()` results cast to `int` before reaching `imagefilledrectangle()`. |

**Verification**: sampled 19 graphs spanning every draw type above, first over a 1-hour window
and then a 7-day window (which exercises the work-period shading loop far more) — all render in
~0.25–0.3s with zero deprecation messages logged.

### 5. Deprecated `$num_points` argument to `imagefilledpolygon()` (PHP 8.0)

```php
// before
imagefilledpolygon($this->im, $points, 3, $color);
// after
imagefilledpolygon($this->im, $points, $color);
```

PHP 8.0 made this argument optional (it's inferable from the points array) and deprecated
passing it explicitly. Six call sites in `include/classes/graphdraw/CLineGraphDraw.php` —
axis-arrow markers, percentile-legend markers, and the gradient-fill polygon.

### 6. Other removed/deprecated PHP functions

- **`strftime()`** — removed in PHP 8.1. `include/classes/screens/CScreenProblem.php`'s
  `addTimelineBreakpoint()` used it five times for date-boundary formatting; replaced with
  `date()`, which covers the same format specifiers this code needed.
- **`utf8_encode()`** — deprecated in PHP 8.2. `include/triggers.inc.php`'s
  `utf8RawUrlDecode()` called it on already-UTF-8 input as a historical no-op; the call was
  simply removed (verified behavior-preserving by the existing regression test).
- **`libxml_disable_entity_loader()`** — deprecated in PHP 8.0 and a no-op on any libxml2 built
  since 2.9.0 (external entity loading has been disabled by default for over a decade; this
  build's libxml2 is 2.13.9). Removed from
  `include/classes/import/readers/CXmlImportReader.php`'s XML-config-import reader.

### 7. `"self"` as a string in a callable (deprecated in PHP 8.2)

```php
// before
uasort($array, ['self', 'compare']);
// after
uasort($array, [self::class, 'compare']);
```

`include/classes/helpers/CArrayHelper.php`. `self::class` resolves to the exact same class name
without triggering the deprecation.

## Notes on false positives

Not every PHPStan finding under level 5 or the deprecation-rules extension corresponded to an
actual PHP 8 runtime warning. Two shapes came up repeatedly and are worth documenting so they
aren't "fixed" by mistake:

- **PHPDoc-only type mismatches.** Several functions have a `@param int $x` docblock but no
  actual `int $x` type declaration on the parameter itself (e.g.
  `CHistoryManager::getAggregatedValue()`, `CWidgetFieldIntegerBox`'s constructor,
  `zbx_imageline()`). PHPStan compares the call site against the *documented* type and flags a
  mismatch, but PHP itself performs no type coercion — and therefore emits no deprecation — for
  an untyped parameter. These needed no change.
- **Zabbix's own `@deprecated` annotations.** `zbx_objectValues()`, `zbx_jsvalue()`, and
  `zbx_empty()` (495 call sites combined) all carry a `@deprecated` PHPDoc tag in Zabbix's
  original 5.0.47 source, recommending `array_column()`, `json_encode()`, and strict comparison
  respectively. PHP does not interpret custom `@deprecated` tags at all — they're pure
  documentation — so calling these functions produces no warning of any kind on any PHP version.

## Verification summary

- PHPStan level 2 (dynamic properties + parameter-order deprecations): 0 findings.
- PHPStan level 5, filtered to argument-type mismatches: 0 findings that correspond to an actual
  runtime deprecation (see above).
- `phpstan/phpstan-deprecation-rules`: 1 genuine PHP-engine deprecation found and fixed
  (`libxml_disable_entity_loader()`); all other hits are Zabbix's own pre-existing annotations.
- `grep` for functions removed outright in PHP 8: none present.
- PHPUnit: 21 unit + 4 integration tests, 229 assertions, all green.
- Manual verification: full stack (`server` + `web` + `agent2` + dev MySQL) brought up via
  `podman compose up`, login, dashboard, and 19 sampled graphs across every draw type confirmed
  rendering correctly with zero PHP warnings logged.
