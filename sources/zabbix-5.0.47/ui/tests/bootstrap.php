<?php declare(strict_types=1);
/**
 * PHPUnit bootstrap for the Zabbix 5.0.47 ui/ PHP8 compatibility migration.
 *
 * This file is test-only infrastructure. It deliberately does NOT modify, wrap, or replace the existing
 * production autoloader (include/classes/core/CAutoloader.php) or ZBase itself — per team-practices.md
 * #Testing Posture, the two autoload paths must stay completely separate. Instead this bootstrap mirrors
 * the exact sequence ZBase::init() runs in production (autoloader registration, the local API client/wrapper
 * wiring, then the same "system includes" + "page specific includes" require list), so that application
 * classes and their global-function dependencies (select_config(), update_config(), getMonthCaption(),
 * DBconnect(), ...) resolve exactly as they do at runtime — without ZBase's DB-connect-or-die/session/HTTP
 * request handling, which a test process must control for itself instead.
 *
 * NOTE: both the include-path list and the required-file list below are a deliberate, documented copy of
 * ZBase::getIncludePaths() / ZBase::init() as of this migration (5.0.47). This is a known trade-off of
 * building a test harness around a legacy, non-PSR-4, hand-rolled bootstrap without touching that bootstrap
 * itself: if a future change to either list in ZBase.php lands, this file must be updated to match.
 */

error_reporting(E_ALL);

define('ZBX_TESTS_ROOT_DIR', dirname(__DIR__));

// CLI SAPI does not populate $_SERVER['REQUEST_URI']; CSession::getDefaultCookiePath() (called from
// CController's constructor via CSession::start()) dereferences it, so tests need a harmless stand-in.
if (!isset($_SERVER['REQUEST_URI'])) {
	$_SERVER['REQUEST_URI'] = '/zabbix.php';
}

// --- Mirrors ZBase::initAutoloader() / ZBase::getIncludePaths() -----------------------------------------

require_once ZBX_TESTS_ROOT_DIR.'/include/classes/core/CAutoloader.php';

$include_paths = [
	'/include/classes/api',
	'/include/classes/api/services',
	'/include/classes/api/helpers',
	'/include/classes/api/managers',
	'/include/classes/api/clients',
	'/include/classes/api/wrappers',
	'/include/classes/core',
	'/include/classes/mvc',
	'/include/classes/db',
	'/include/classes/debug',
	'/include/classes/validators',
	'/include/classes/validators/schema',
	'/include/classes/validators/string',
	'/include/classes/validators/object',
	'/include/classes/validators/hostgroup',
	'/include/classes/validators/host',
	'/include/classes/validators/hostprototype',
	'/include/classes/validators/event',
	'/include/classes/export',
	'/include/classes/export/writers',
	'/include/classes/export/elements',
	'/include/classes/graph',
	'/include/classes/graphdraw',
	'/include/classes/import',
	'/include/classes/import/converters',
	'/include/classes/import/importers',
	'/include/classes/import/preprocessors',
	'/include/classes/import/readers',
	'/include/classes/import/validators',
	'/include/classes/items',
	'/include/classes/triggers',
	'/include/classes/server',
	'/include/classes/screens',
	'/include/classes/services',
	'/include/classes/sysmaps',
	'/include/classes/helpers',
	'/include/classes/helpers/trigger',
	'/include/classes/macros',
	'/include/classes/tree',
	'/include/classes/html',
	'/include/classes/html/pageheader',
	'/include/classes/html/svg',
	'/include/classes/html/widget',
	'/include/classes/html/interfaces',
	'/include/classes/parsers',
	'/include/classes/parsers/results',
	'/include/classes/controllers',
	'/include/classes/routing',
	'/include/classes/json',
	'/include/classes/user',
	'/include/classes/setup',
	'/include/classes/regexp',
	'/include/classes/ldap',
	'/include/classes/pagefilter',
	'/include/classes/widgets/fields',
	'/include/classes/widgets/forms',
	'/include/classes/widgets',
	'/include/classes/xml',
	'/local/app/controllers',
	'/app/controllers'
];

$autoloader = new CAutoloader();
$autoloader->addNamespace('', array_map(
	static fn(string $path): string => ZBX_TESTS_ROOT_DIR.$path,
	$include_paths
));
$autoloader->addNamespace('Core', [ZBX_TESTS_ROOT_DIR.'/include/classes/core']);
$autoloader->register();

// --- Mirrors the API wrapper wiring in ZBase::init() -----------------------------------------------------
// Needed so any code path that happens to call the API::...() facade (e.g. CControllerAuthenticationUpdate's
// invalidateSessions(), which this test suite otherwise avoids triggering) fails on its own merits rather
// than with an unrelated "wrapper not set" error.

$api_service_factory = new CApiServiceFactory();
$api_client = new CLocalApiClient();
$api_client->setServiceFactory($api_service_factory);
$api_wrapper = new CFrontendApiWrapper($api_client);
$api_wrapper->setProfiler(CProfiler::getInstance());
API::setWrapper($api_wrapper);
API::setApiServiceFactory($api_service_factory);

// --- Mirrors ZBase::init()'s "system includes" + "page specific includes" ---------------------------------
// Chdir to the ui/ root first: like ZBase, these are relative paths (set_include_path() is also skipped
// deliberately — the CAutoloader instance above already covers every class these files need).

$previous_cwd = getcwd();
chdir(ZBX_TESTS_ROOT_DIR);

require_once 'include/debug.inc.php';
require_once 'include/gettextwrapper.inc.php';
require_once 'include/defines.inc.php';
require_once 'include/func.inc.php';
require_once 'include/html.inc.php';
require_once 'include/perm.inc.php';
require_once 'include/menu.inc.php';
require_once 'include/audit.inc.php';
require_once 'include/js.inc.php';
require_once 'include/users.inc.php';
require_once 'include/validate.inc.php';
require_once 'include/profiles.inc.php';
require_once 'include/locales.inc.php';
require_once 'include/db.inc.php';

require_once 'include/actions.inc.php';
require_once 'include/discovery.inc.php';
require_once 'include/draw.inc.php';
require_once 'include/events.inc.php';
require_once 'include/graphs.inc.php';
require_once 'include/hostgroups.inc.php';
require_once 'include/hosts.inc.php';
require_once 'include/httptest.inc.php';
require_once 'include/ident.inc.php';
require_once 'include/images.inc.php';
require_once 'include/items.inc.php';
require_once 'include/maintenances.inc.php';
require_once 'include/maps.inc.php';
require_once 'include/media.inc.php';
require_once 'include/services.inc.php';
require_once 'include/sounds.inc.php';
require_once 'include/triggers.inc.php';
require_once 'include/valuemap.inc.php';

if ($previous_cwd !== false) {
	chdir($previous_cwd);
}

// --- Global $DB connection-parameter array ----------------------------------------------------------------
// Consumed by DBconnect() (include/db.inc.php). No connection is opened here — only populated with
// parameters — so the pure unit tests (CScreenProblemBreakpointTest, TriggersIncDecodeTest, CFrontendSetupTest)
// never require a reachable database. Only tests/integration/AuthenticationConfigTest.php calls DBconnect(),
// lazily in its own setUpBeforeClass(), skipping itself gracefully when no test database is reachable.

global $DB;
$DB = [
	'TYPE' => ZBX_DB_MYSQL,
	'SERVER' => getenv('ZBX_TEST_DB_HOST') ?: '127.0.0.1',
	'PORT' => (int) (getenv('ZBX_TEST_DB_PORT') ?: 3306),
	'USER' => getenv('ZBX_TEST_DB_USER') ?: 'zabbix',
	'PASSWORD' => getenv('ZBX_TEST_DB_PASSWORD') ?: 'zabbix',
	'DATABASE' => getenv('ZBX_TEST_DB_DATABASE') ?: 'zabbix',
	'SCHEMA' => '',
	'ENCRYPTION' => false,
	'KEY_FILE' => '',
	'CERT_FILE' => '',
	'CA_FILE' => '',
	'VERIFY_HOST' => true,
	'CIPHER_LIST' => ''
];
