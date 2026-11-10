"""Tests for scripts/ci_summary.py (the GitHub Actions Job Summary).

The summary is display-only, so what matters is: the counts match the Trivy report, a bad input or an
unwritable file never raises, and the SBOM comparison reports the right packages.

Run: python3 -m unittest discover -s tests/ci_summary -v   (standard library only)
"""
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import ci_summary as cs  # noqa: E402


def trivy_report(*vulns):
    return {"Results": [{"Target": "t", "Vulnerabilities": list(vulns)}, {"Target": "empty", "Vulnerabilities": None}]}


def vuln(severity, fixed=None):
    item = {"VulnerabilityID": "CVE-2026-0001", "Severity": severity}
    if fixed:
        item["FixedVersion"] = fixed
    return item


def apk(name, version):
    return {"type": "library", "name": name, "version": version, "purl": f"pkg:apk/alpine/{name}@{version}"}


class TrivyRecordTest(unittest.TestCase):
    def test_counts_by_severity_and_fixable_high(self):
        report = trivy_report(
            vuln("CRITICAL", "2"), vuln("HIGH", "1"), vuln("HIGH"), vuln("MEDIUM", "3"), vuln("LOW"), vuln("UNKNOWN")
        )
        record = cs.build_trivy_record(report, "img:1", "Pass")

        self.assertEqual(record["counts"], {"Critical": 1, "High": 2, "Medium": 1, "Low": 2})
        self.assertEqual(record["fixable_high"], 2)  # the Critical and one High have a fix; Medium does not count
        self.assertEqual(record["blocking"], 1)
        self.assertEqual(record["verdict"], "Pass")

    def test_report_without_vulnerabilities(self):
        record = cs.build_trivy_record({"Results": None}, "img:1", "Pass")
        self.assertEqual(sum(record["counts"].values()), 0)


class RecordFileTest(unittest.TestCase):
    def test_bad_report_or_unwritable_file_never_fails_the_caller(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.json"
            bad.write_text("not json", encoding="utf-8")
            blocker = Path(tmp) / "file"
            blocker.write_text("x", encoding="utf-8")
            good = Path(tmp) / "good.json"
            good.write_text(json.dumps(trivy_report(vuln("HIGH"))), encoding="utf-8")

            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(cs.main(["record-trivy", "--input", str(bad), "--target", "i", "--verdict", "Pass",
                                          "--summary-file", str(Path(tmp) / "r.jsonl")]), 0)
                self.assertEqual(cs.main(["record-trivy", "--input", str(good), "--target", "i", "--verdict", "Pass",
                                          "--summary-file", str(blocker / "r.jsonl")]), 0)
                self.assertEqual(cs.main(["record-step", "--name", "n", "--result", "Pass",
                                          "--summary-file", str(blocker / "r.jsonl")]), 0)
            self.assertIn("[warn]", err.getvalue())
            self.assertFalse((Path(tmp) / "r.jsonl").exists())

    def test_load_records_skips_blank_and_corrupt_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "r.jsonl"
            path.write_text('{"kind": "step", "name": "a", "result": "Pass"}\n\nnot json\n[1]\n', encoding="utf-8")
            self.assertEqual(cs.load_records(path), [{"kind": "step", "name": "a", "result": "Pass"}])
            self.assertEqual(cs.load_records(Path(tmp) / "missing"), [])
            self.assertEqual(cs.load_records(None), [])


class SbomDiffTest(unittest.TestCase):
    def write(self, directory, key, tag, components):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"{key}_{tag}.cyclonedx.json").write_text(json.dumps({"components": components}), encoding="utf-8")

    def test_updated_added_removed_and_os(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            os_old = {"type": "operating-system", "name": "alpine", "version": "3.24.3"}
            os_new = {"type": "operating-system", "name": "alpine", "version": "3.24.4"}
            self.write(root / "prev", "localhost_img", "5.0.47-custom", [os_old, apk("zlib", "1"), apk("gone", "1"), apk("same", "1")])
            self.write(root / "new", "localhost_img", "5.0.47-custom", [os_new, apk("zlib", "2"), apk("fresh", "1"), apk("same", "1")])

            prev = cs.load_sbom_dir(root / "prev")["localhost_img"]
            new = cs.load_sbom_dir(root / "new")["localhost_img"]
            added, removed, changed = cs.diff_packages(prev["packages"], new["packages"])

            self.assertEqual(changed, [("zlib", "1", "2")])
            self.assertEqual(added, [("fresh", "1")])
            self.assertEqual(removed, [("gone", "1")])
            self.assertEqual((prev["os"], new["os"]), ("alpine 3.24.3", "alpine 3.24.4"))
            self.assertEqual(new["tag"], "5.0.47-custom")

    def test_files_and_unversioned_components_are_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.write(Path(tmp), "img", "t", [
                {"type": "file", "name": "/etc/passwd", "version": "1"},
                {"type": "application", "name": "composer.lock"},
                apk("busybox", "1.0"),
            ])
            self.assertEqual(list(cs.load_sbom_dir(tmp)["img"]["packages"].values()), [("busybox", "1.0")])


class RenderTest(unittest.TestCase):
    META = {"zabbix_version": "5.0.47", "event": "schedule", "build_date": "20261109"}

    def records(self, verdict="Pass", go="Pass"):
        return [
            {"kind": "scan", "tool": "trivy", "target": "localhost/web:5.0.47-custom", "verdict": verdict,
             "counts": {"Critical": 0 if verdict == "Pass" else 2, "High": 3, "Medium": 1, "Low": 4},
             "fixable_high": 1, "blocking": 0 if verdict == "Pass" else 2},
            {"kind": "step", "name": "govulncheck (zabbix_agent2)", "result": go},
        ]

    def test_clean_run(self):
        text = cs.render_summary(self.records(), {}, {}, self.META)
        self.assertIn("✅", text.splitlines()[0])
        self.assertIn("Zabbix 5.0.47", text)
        self.assertIn("| `localhost/web:5.0.47-custom` | 0 | 3 | 1 | 4 | 1 | ✅ |", text)
        self.assertIn("production", text)

    def test_failing_gate_is_named(self):
        text = cs.render_summary(self.records(verdict="Fail", go="Fail"), {}, {}, self.META)
        self.assertIn("❌", text.splitlines()[0])
        self.assertIn("trivy (localhost/web:5.0.47-custom)", text)
        self.assertIn("govulncheck (zabbix_agent2)", text)

    def test_skipped_steps_are_a_warning_not_success(self):
        records = self.records() + [{"kind": "step", "name": "smoke", "result": "Skipped"}]
        text = cs.render_summary(records, {}, {}, self.META)
        self.assertNotIn("✅", text.splitlines()[0])
        self.assertIn("smoke", text.splitlines()[2])

    def test_no_records_warns(self):
        self.assertIn("記録がありません", cs.render_summary([], {}, {}, self.META))

    def test_comparison_texts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "new").mkdir()
            (root / "new" / "img_t.cyclonedx.json").write_text(json.dumps({"components": [apk("a", "1")]}), encoding="utf-8")
            new = cs.load_sbom_dir(root / "new")
            self.assertIn("比較できません", cs.render_summary([], new, {}, self.META))
            self.assertIn("変更なし", cs.render_summary([], new, new, self.META))

    def test_render_command_maps_step_outcomes_and_always_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = io.StringIO()
            with redirect_stdout(out):
                code = cs.main(["render", "--records", str(Path(tmp) / "none.jsonl"), "--zabbix-version", "5.0.47",
                                "--step", "テスト=success", "--step", "スモーク=failure", "--step", "後続=skipped"])
            text = out.getvalue()
            self.assertEqual(code, 0)
            self.assertIn("| テスト | ✅ Pass |", text)
            self.assertIn("| スモーク | ❌ Fail |", text)
            self.assertIn("| 後続 | ➖ Skipped |", text)
            self.assertIn("ゲートがFailしました", text)

    def test_render_never_raises_on_internal_errors(self):
        original = cs.render_summary
        cs.render_summary = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("壊れた"))
        try:
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(cs.main(["render"]), 0)
            self.assertIn("サマリーを作れませんでした", out.getvalue())
        finally:
            cs.render_summary = original


if __name__ == "__main__":
    unittest.main()
