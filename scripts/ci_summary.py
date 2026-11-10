#!/usr/bin/env python3
"""Turn the CI results into the Markdown shown on a GitHub Actions run page (the Job Summary).

Goal: after every weekly run, show (1) what changed since the previous build and (2) how far the
vulnerability checks got, without opening thousands of lines of log. This is display-only: it never
changes a gate, and it always exits 0 when rendering (so it can never turn a green run red).

Standard library only (this project has no Python dependencies in CI).

  record-trivy  append one Trivy result (counts by severity) to the records file
  record-step   append one pass/fail item to the records file
  render        print the Markdown (redirect it to $GITHUB_STEP_SUMMARY)

Records file: JSON Lines, one object per line.
  {"kind": "scan", "tool": "trivy", "target": "<image>", "verdict": "Pass",
   "counts": {"Critical": 0, "High": 2, "Medium": 1, "Low": 0}, "fixable_high": 1, "blocking": 0}
  {"kind": "step", "name": "govulncheck (zabbix_agent2)", "result": "Pass"}

SBOMs (Trivy `--format cyclonedx`) are named `<image>_<tag>.cyclonedx.json`, with `/` and `:` replaced
by `_`; `render` compares the current directory with the previous run's.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SEVERITIES = ("Critical", "High", "Medium", "Low")
_TRIVY_SEVERITY = {"CRITICAL": "Critical", "HIGH": "High", "MEDIUM": "Medium", "LOW": "Low", "UNKNOWN": "Low"}
SBOM_SUFFIX = ".cyclonedx.json"
MAX_LISTED_CHANGES = 40

_OK, _NG, _WARN = "✅", "❌", "⚠️"
_OUTCOME_TO_RESULT = {"success": "Pass", "failure": "Fail", "cancelled": "Fail", "skipped": "Skipped"}


# --- records (producer side) ---------------------------------------------------------------------


def append_record(path: str | Path, record: Dict[str, Any]) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def load_records(path: str | Path | None) -> List[Dict[str, Any]]:
    """Read the records file. A missing file or a corrupt line is skipped (display-only)."""
    if not path or not Path(path).is_file():
        return []
    records: List[Dict[str, Any]] = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


def build_trivy_record(data: Dict[str, Any], target: str, verdict: str, gate_severity: str = "Critical") -> Dict[str, Any]:
    """Count the findings in a Trivy `--format json` report.

    fixable_high: High-or-worse findings that already have a fixed version, i.e. what is worth acting on.
    blocking: findings at the gate severity (this project blocks on CRITICAL only).
    """
    counts = {severity: 0 for severity in SEVERITIES}
    fixable_high = 0
    for result in data.get("Results", []) or []:
        for vuln in result.get("Vulnerabilities", []) or []:
            severity = _TRIVY_SEVERITY.get((vuln.get("Severity") or "").upper(), "Low")
            counts[severity] += 1
            if severity in ("Critical", "High") and vuln.get("FixedVersion"):
                fixable_high += 1
    return {
        "kind": "scan",
        "tool": "trivy",
        "target": target,
        "verdict": verdict,
        "counts": counts,
        "fixable_high": fixable_high,
        "blocking": counts.get(gate_severity, 0),
    }


# --- SBOM comparison -----------------------------------------------------------------------------


def _image_key_and_tag(filename: str) -> Tuple[str, str]:
    stem = filename[: -len(SBOM_SUFFIX)] if filename.endswith(SBOM_SUFFIX) else filename
    if "_" in stem:
        key, tag = stem.rsplit("_", 1)
        return key, tag
    return stem, ""


def load_sbom_dir(directory: str | Path | None) -> Dict[str, Dict[str, Any]]:
    """Per image: {tag, os, packages}. packages maps a version-less id to (name, version)."""
    result: Dict[str, Dict[str, Any]] = {}
    if not directory or not Path(directory).is_dir():
        return result
    for path in sorted(Path(directory).glob(f"*{SBOM_SUFFIX}")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        key, tag = _image_key_and_tag(path.name)
        packages: Dict[str, Tuple[str, str]] = {}
        os_text = ""
        for component in data.get("components", []) or []:
            ctype, name, version = component.get("type", ""), component.get("name", ""), component.get("version", "")
            if ctype == "operating-system":
                os_text = f"{name} {version}".strip()
                continue
            if ctype == "file" or not name or not version:
                continue
            purl = component.get("purl") or ""
            packages[purl.split("@", 1)[0] if purl else f"{ctype}:{name}"] = (name, version)
        result[key] = {"tag": tag, "os": os_text, "packages": packages}
    return result


def diff_packages(old: Dict[str, Tuple[str, str]], new: Dict[str, Tuple[str, str]]):
    added = sorted((n, v) for ident, (n, v) in new.items() if ident not in old)
    removed = sorted((n, v) for ident, (n, v) in old.items() if ident not in new)
    changed = sorted(
        (new[i][0], old[i][1], new[i][1]) for i in new if i in old and old[i][1] != new[i][1]
    )
    return added, removed, changed


def trivy_db_updated_at() -> Optional[str]:
    try:
        proc = subprocess.run(["trivy", "version", "--format", "json"], capture_output=True, text=True, timeout=30, check=False)
        db = (json.loads(proc.stdout or "{}").get("VulnerabilityDB")) or {}
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None
    return db.get("UpdatedAt") or db.get("DownloadedAt")


# --- Markdown ------------------------------------------------------------------------------------


def _mark(result: str) -> str:
    return _OK if result in ("Pass", "Clean") else (_NG if result in ("Fail", "Blocked") else "➖")


def _overall(scans: List[Dict[str, Any]], steps: List[Dict[str, Any]]) -> Tuple[str, str]:
    bad = [f"trivy ({s.get('target')})" for s in scans if s.get("verdict") != "Pass"]
    bad += [str(s.get("name")) for s in steps if s.get("result") in ("Fail", "Blocked")]
    if bad:
        return _NG, "ゲートがFailしました: " + ", ".join(bad)
    if not scans and not steps:
        return _WARN, "記録がありません(検証が始まる前に止まった可能性があります)"
    skipped = [str(s.get("name")) for s in steps if s.get("result") == "Skipped"]
    if skipped:
        return _WARN, "実行されなかった項目があります(前の項目の失敗か中断): " + ", ".join(skipped)
    return _OK, "検証ゲートはすべてPassしました"


def _render_changes(new: Dict[str, Dict[str, Any]], prev: Dict[str, Dict[str, Any]]) -> List[str]:
    lines = ["## 前回ビルドからの変更(SBOM比較)", ""]
    if not new:
        return lines + ["今回のSBOMがありません(SBOM生成より前に止まった可能性があります)。", ""]
    if not prev:
        return lines + ["前回のSBOMが見つからないため、比較できません(初回、または保存期間切れ)。", ""]

    body: List[str] = []
    unchanged: List[str] = []
    any_change = False
    for key in sorted(new):
        cur, old = new[key], prev.get(key)
        if old is None:
            body += [f"- `{key}`: 前回のSBOMに無いイメージです(新規)。", ""]
            any_change = True
            continue
        added, removed, changed = diff_packages(old["packages"], cur["packages"])
        os_changed = old["os"] != cur["os"]
        if not (added or removed or changed or os_changed):
            unchanged.append(f"- `{key}`: 変更なし")
            continue
        any_change = True
        parts = [f"更新{len(changed)}" if changed else "", f"追加{len(added)}" if added else "", f"削除{len(removed)}" if removed else ""]
        summary = f"<code>{key}</code>: " + (" / ".join(p for p in parts if p) or "パッケージの変更なし")
        if os_changed:
            summary += f" / OS {old['os'] or '?'} → {cur['os'] or '?'}"
        rows = [f"| 更新 | `{n}` | {o} → {v} |" for n, o, v in changed]
        rows += [f"| 追加 | `{n}` | {v} |" for n, v in added]
        rows += [f"| 削除 | `{n}` | {v} |" for n, v in removed]
        body += ["<details>", f"<summary>{summary}</summary>", "", "| 区分 | パッケージ | バージョン |", "|---|---|---|"]
        body += rows[:MAX_LISTED_CHANGES]
        if len(rows) > MAX_LISTED_CHANGES:
            body.append(f"| … | ほか{len(rows) - MAX_LISTED_CHANGES}件 | |")
        body += ["", "</details>", ""]
    if not any_change:
        lines += ["パッケージの更新はありません(ベースイメージ・依存とも前回と同じです)。", ""]
    lines += body
    if unchanged:
        lines += unchanged + [""]
    return lines


def render_summary(
    records: List[Dict[str, Any]],
    new_sbom: Dict[str, Dict[str, Any]],
    prev_sbom: Dict[str, Dict[str, Any]],
    meta: Dict[str, str],
) -> str:
    scans = [r for r in records if r.get("kind") == "scan"]
    steps = [r for r in records if r.get("kind") == "step"]
    icon, headline = _overall(scans, steps)

    title = f"# {icon} 脆弱性チェックと前回からの変更"
    if meta.get("zabbix_version"):
        title += f" — Zabbix {meta['zabbix_version']}"
    out: List[str] = [title, "", headline, ""]

    info: List[Tuple[str, str]] = []
    if meta.get("event"):
        info.append(("実行のきっかけ", meta["event"]))
    if meta.get("build_date"):
        info.append(("ビルド日", meta["build_date"]))
    os_texts = sorted({v["os"] for v in new_sbom.values() if v.get("os")})
    if os_texts:
        info.append(("イメージ内のOS", ", ".join(os_texts)))
    if meta.get("trivy_db"):
        info.append(("Trivy脆弱性DBの更新", meta["trivy_db"]))
    if info:
        out += ["| 項目 | 内容 |", "|---|---|"] + [f"| {k} | {v} |" for k, v in info] + [""]

    out += _render_changes(new_sbom, prev_sbom)

    out += ["## 脆弱性チェックの結果", ""]
    if scans:
        out += [
            "### Trivy(イメージごと)",
            "",
            "| イメージ | Critical | High | Medium | Low | 修正版あり(High以上) | 判定 |",
            "|---|---:|---:|---:|---:|---:|:---:|",
        ]
        for s in scans:
            c = s.get("counts", {})
            out.append(
                f"| `{s.get('target')}` | " + " | ".join(str(c.get(sev, 0)) for sev in SEVERITIES)
                + f" | {s.get('fixable_high', 0)} | {_mark(s.get('verdict', ''))} |"
            )
        out += [
            "",
            "Criticalが1件でもあると失敗します。High以下は参考情報で、ゲートにはなりません"
            "(「修正版あり」は、すでに修正版が出ているHigh以上の件数=対応の目安です)。",
            "",
        ]
    if steps:
        out += ["### その他の項目", "", "| 項目 | 結果 |", "|---|:---:|"]
        out += [f"| {s.get('name')} | {_mark(str(s.get('result')))} {s.get('result')} |" for s in steps]
        out.append("")
    if not scans and not steps:
        out += ["記録がありません。", ""]
    out += [
        "---",
        "このジョブは検証だけを行います。Docker Hubへの公開は、`production` 環境の承認後に `Publish` ジョブが行います"
        "(承認するまでRunは waiting のままです)。",
        "",
    ]
    return "\n".join(out)


# --- CLI -----------------------------------------------------------------------------------------


def _cmd_record_trivy(args: argparse.Namespace) -> int:
    # Display-only: a bad report or an unwritable file must never change the scan's result.
    try:
        data = json.loads(Path(args.input).read_text(encoding="utf-8"))
        append_record(args.summary_file, build_trivy_record(data, args.target, args.verdict, args.gate_severity))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[warn] could not record the Trivy summary (the scan result is unaffected): {exc}", file=sys.stderr)
    return 0


def _cmd_record_step(args: argparse.Namespace) -> int:
    try:
        append_record(args.summary_file, {"kind": "step", "name": args.name, "result": args.result})
    except OSError as exc:
        print(f"[warn] could not record the step (the result is unaffected): {exc}", file=sys.stderr)
    return 0


def _cmd_render(args: argparse.Namespace) -> int:
    meta = {
        "zabbix_version": args.zabbix_version or "",
        "event": args.event or "",
        "build_date": args.build_date or "",
    }
    try:
        records = load_records(args.records)
        # --step "NAME=outcome" takes a GitHub Actions step outcome (success/failure/skipped/cancelled).
        for item in args.step or []:
            name, _, outcome = item.rpartition("=")
            records.append({"kind": "step", "name": name, "result": _OUTCOME_TO_RESULT.get(outcome, outcome)})
        if args.trivy_db:
            updated = trivy_db_updated_at()
            if updated:
                meta["trivy_db"] = updated
        text = render_summary(records, load_sbom_dir(args.sbom_dir), load_sbom_dir(args.prev_sbom_dir), meta)
    except Exception as exc:  # display-only: nothing here may break the run
        text = f"# {_WARN} サマリーを作れませんでした\n\n`{type(exc).__name__}: {exc}`\n"
    sys.stdout.write(text)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("record-trivy", help="append one Trivy JSON report's counts to the records file")
    p.add_argument("--input", required=True, help="trivy image --format json output")
    p.add_argument("--target", required=True, help="image name")
    p.add_argument("--verdict", required=True, choices=("Pass", "Fail"))
    p.add_argument("--gate-severity", default="Critical", choices=SEVERITIES)
    p.add_argument("--summary-file", required=True)
    p.set_defaults(func=_cmd_record_trivy)

    p = sub.add_parser("record-step", help="append one pass/fail item to the records file")
    p.add_argument("--name", required=True)
    p.add_argument("--result", required=True, choices=("Pass", "Fail", "Clean", "Blocked", "Skipped"))
    p.add_argument("--summary-file", required=True)
    p.set_defaults(func=_cmd_record_step)

    p = sub.add_parser("render", help="print the Markdown summary (always exits 0)")
    p.add_argument("--records", default=None)
    p.add_argument("--sbom-dir", default=None, help="this run's SBOMs")
    p.add_argument("--prev-sbom-dir", default=None, help="the previous run's SBOMs (no comparison if absent)")
    p.add_argument("--zabbix-version", default=None)
    p.add_argument("--event", default=None)
    p.add_argument("--build-date", default=None)
    p.add_argument("--step", action="append", help='add an item from a step outcome: "NAME=success|failure|skipped|cancelled"')
    p.add_argument("--trivy-db", action="store_true", help="also show when Trivy's vulnerability DB was updated")
    p.set_defaults(func=_cmd_render)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
