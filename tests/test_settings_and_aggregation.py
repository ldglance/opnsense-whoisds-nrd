# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
import json
import tempfile
import unittest
from contextlib import ExitStack
from datetime import date
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "src/opnsense/scripts/whoisds_nrd/updater.py"
SPEC = importlib.util.spec_from_file_location("whoisds_nrd_updater", SCRIPT)
updater = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(updater)


class BasePluginTest(unittest.TestCase):
    def setUp(self):
        updater._LOADED_ARCHIVES.clear()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.daily = self.root / "daily"
        self.daily.mkdir()
        self.output = self.root / "aggregate.txt"
        self.run_state = self.root / "run-state.json"
        self.settings = self.root / "settings.conf"

    def patched_paths(self):
        stack = ExitStack()
        stack.enter_context(patch.object(updater, "DAILY_DIR", self.daily))
        stack.enter_context(patch.object(updater, "OUTPUT_FILE", self.output))
        stack.enter_context(patch.object(updater, "RUN_STATE_FILE", self.run_state))
        return stack

    def seed(self, days):
        for day in days:
            (self.daily / f"{day}.txt").write_text("a.example\nb.example\n")


class TldExclusionTests(BasePluginTest):
    def test_opnsense_model_mask_is_a_delimited_regex(self):
        from xml.etree import ElementTree
        model_path = SCRIPT.parents[2] / "mvc/app/models/OPNsense/WhoisdsNrd/WhoisdsNrd.xml"
        xml = ElementTree.parse(model_path)
        mask = xml.findtext(".//excludedTlds/Mask")
        self.assertEqual(mask, "/^[A-Za-z0-9.,* -]*$/u")
        import re
        pattern, flags = mask.rsplit("/", 2)[1], mask.rsplit("/", 2)[2]
        self.assertTrue(re.fullmatch(pattern, "ru,cn,xyz,shop,bond,top"))

    def test_comma_separated_tlds_and_suffixes(self):
        self.assertEqual(updater.parse_tld_exclusions("ru, cn,xyz,.co.uk,*.us"), {"ru", "cn", "xyz", "co.uk", "us"})

    def test_bad_suffix_is_rejected(self):
        with self.assertRaises(ValueError):
            updater.parse_tld_exclusions("ru,not a tld,xyz")

    def test_matching_uses_dns_label_boundaries(self):
        suffixes = {"ru", "co.uk"}
        self.assertTrue(updater.domain_matches_excluded_suffix("example.ru", suffixes))
        self.assertTrue(updater.domain_matches_excluded_suffix("a.b.example.ru", suffixes))
        self.assertTrue(updater.domain_matches_excluded_suffix("example.co.uk", suffixes))
        self.assertFalse(updater.domain_matches_excluded_suffix("example.russia", suffixes))
        self.assertFalse(updater.domain_matches_excluded_suffix("notru.example.com", suffixes))

    def test_filter_returns_count_and_retains_other_domains(self):
        kept, excluded = updater.filter_excluded_tlds(
            {"one.ru", "two.cn", "safe.example", "child.safe.example"}, {"ru", "cn"}
        )
        self.assertEqual(excluded, 2)
        self.assertEqual(kept, {"safe.example", "child.safe.example"})

    def test_missing_settings_uses_three_day_default_and_no_exclusions(self):
        with patch.object(updater, "SETTINGS_FILE", self.root / "missing.conf"):
            self.assertEqual(updater.load_settings(), (3, set()))

    def test_settings_file_loads_retention_and_tld_values(self):
        self.settings.write_text("RETENTION_DAYS=4\nEXCLUDED_TLDS=ru,cn,xyz\n")
        with patch.object(updater, "SETTINGS_FILE", self.settings):
            self.assertEqual(updater.load_settings(), (4, {"ru", "cn", "xyz"}))

    def test_settings_file_rejects_retention_outside_range(self):
        self.settings.write_text("RETENTION_DAYS=0\nEXCLUDED_TLDS=\n")
        with patch.object(updater, "SETTINGS_FILE", self.settings):
            with self.assertRaises(ValueError):
                updater.load_settings()


class AggregateOutputTests(BasePluginTest):
    def test_retention_prunes_and_tld_filter_only_affects_published_feed(self):
        (self.daily / "2026-11-16.txt").write_text("old.example\n")
        (self.daily / "2026-11-17.txt").write_text("bad.ru\ngood.example\nchild.good.example\n")
        with self.patched_paths(), patch.object(updater, "MIN_VALID_DOMAINS", 1):
            _raw, published, valid_days, _raw_count, pruned, rebuilt = updater.aggregate_local_archives(
                date(2026, 11, 17), 1, {"ru"}
            )
        self.assertTrue(rebuilt)
        self.assertEqual(pruned, 1)
        self.assertEqual(valid_days, 1)
        self.assertEqual(published, {"good.example", "child.good.example"})
        self.assertFalse((self.daily / "2026-11-16.txt").exists())
        self.assertIn("bad.ru", (self.daily / "2026-11-17.txt").read_text().splitlines())
        self.assertIn("*.good.example", self.output.read_text().splitlines())
        self.assertNotIn("bad.ru", self.output.read_text().splitlines())

    def test_publishes_apex_and_subdomain_wildcard(self):
        with patch.object(updater, "OUTPUT_FILE", self.output):
            updater.atomic_write_domains(self.output, {"example.com", "sample.net"}, include_subdomain_wildcards=True)
        self.assertEqual(set(self.output.read_text().splitlines()), {
            "example.com", "*.example.com", "sample.net", "*.sample.net"
        })

    def test_unchanged_aggregate_skips_rewrite_and_domain_parsing(self):
        self.seed(["2026-11-17", "2026-11-16"])
        with self.patched_paths(), \
             patch.object(updater, "MIN_VALID_DOMAINS", 1), \
             patch.object(updater, "datetime", RollingDateTests.FixedDateTime), \
             patch.object(updater, "load_settings", return_value=(3, set())), \
             patch.object(updater, "download_day", return_value={"new.example"}):
            first = updater.update_local_store()
            output_stat = self.output.stat()
            with patch.object(updater, "read_valid_daily_file", side_effect=AssertionError("unexpected file parse")), \
                 patch.object(updater, "download_day", side_effect=AssertionError("unexpected network download")):
                second = updater.update_local_store()
            self.assertTrue(first[3])
            self.assertFalse(second[3])
            self.assertEqual(output_stat.st_mtime_ns, self.output.stat().st_mtime_ns)
            state = json.loads(self.run_state.read_text())
            self.assertTrue(state["status_snapshot"]["stats_available"])
            self.assertEqual(state["status_snapshot"]["unique_domains"], 3)

    def test_changing_tld_settings_forces_rebuild_without_download(self):
        self.seed(["2026-11-18", "2026-11-17", "2026-11-16"])
        with self.patched_paths(), \
             patch.object(updater, "MIN_VALID_DOMAINS", 1), \
             patch.object(updater, "datetime", RollingDateTests.FixedDateTime), \
             patch.object(updater, "load_settings", side_effect=[(3, set()), (3, {"ru"})]), \
             patch.object(updater, "download_day", side_effect=AssertionError("existing archives should not download")):
            updater.update_local_store()
            (self.daily / "2026-11-18.txt").write_text("bad.ru\ngood.example\n")
            updater._LOADED_ARCHIVES.clear()
            # The changed file signature is detected and revalidated; settings also changed.
            result = updater.update_local_store()
        self.assertTrue(result[3])
        self.assertNotIn("bad.ru", self.output.read_text().splitlines())


class LightweightStatusTests(BasePluginTest):
    def test_status_reads_snapshot_without_opening_daily_archives_or_aggregate(self):
        status_script = SCRIPT.with_name("status.py")
        spec = importlib.util.spec_from_file_location("whoisds_nrd_status", status_script)
        status = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(status)
        self.run_state.write_text(json.dumps({
            "last_checked_utc": "2026-11-18T19:00:00+00:00",
            "last_successful_update_utc": "2026-11-18T19:00:01+00:00",
            "last_feed_rebuild_utc": "2026-11-18T19:00:00+00:00",
            "last_unbound_ingest_utc": "2026-11-18T19:00:02+00:00",
            "unbound_ingest_status": "verified",
            "status_snapshot": {
                "stats_available": True,
                "unique_domains": 123,
                "retained_days": 3,
                "retention_days": 3,
                "days": [{"date": "2026-11-18", "domains": 123, "size_bytes": 456}],
            },
        }))
        self.output.write_text("feed content deliberately not parsed")
        from io import StringIO
        import contextlib
        with patch.object(status, "RUN_STATE", self.run_state), \
             patch.object(status, "OUT", self.output), \
             patch.object(status, "SETTINGS_FILE", self.settings), \
             patch.object(status.urllib.request, "urlopen", return_value=type("R", (), {"status": 200, "__enter__": lambda x: x, "__exit__": lambda *a: None})()), \
             contextlib.redirect_stdout(StringIO()) as stdout:
            rc = status.main()
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 0)
        self.assertEqual(payload["unique_domains"], 123)
        self.assertEqual(payload["days"][0]["date"], "2026-11-18")
        self.assertTrue(payload["http_endpoint"])
        self.assertEqual(payload["unbound_ingest_status"], "verified")
        self.assertEqual(payload["last_unbound_ingest_utc"], "2026-11-18T19:00:02+00:00")



class RollingDateTests(BasePluginTest):
    class FixedDateTime(__import__("datetime").datetime):
        @classmethod
        def now(cls, tz=None):
            value = cls(2026, 11, 18, 19, 0, 0)
            return value.replace(tzinfo=tz) if tz else value

    def test_newest_date_download_prunes_oldest_only_after_success(self):
        self.seed(["2026-11-15", "2026-11-16", "2026-11-17"])
        with self.patched_paths(), \
             patch.object(updater, "MIN_VALID_DOMAINS", 1), \
             patch.object(updater, "datetime", self.FixedDateTime), \
             patch.object(updater, "load_settings", return_value=(3, set())), \
             patch.object(updater, "download_day", return_value={"new.example"}):
            updater.update_local_store()
        self.assertTrue((self.daily / "2026-11-18.txt").exists())
        self.assertFalse((self.daily / "2026-11-15.txt").exists())
        self.assertTrue((self.daily / "2026-11-16.txt").exists())
        self.assertTrue((self.daily / "2026-11-17.txt").exists())

    def test_rebuild_anchors_to_latest_local_archive_not_calendar_date(self):
        self.seed(["2026-11-15", "2026-11-16", "2026-11-17"])
        with self.patched_paths(), \
             patch.object(updater, "MIN_VALID_DOMAINS", 1), \
             patch.object(updater, "datetime", self.FixedDateTime), \
             patch.object(updater, "load_settings", return_value=(3, set())):
            updater.rebuild_local_store()
        self.assertTrue((self.daily / "2026-11-15.txt").exists())
        self.assertTrue((self.daily / "2026-11-16.txt").exists())
        self.assertTrue((self.daily / "2026-11-17.txt").exists())

    def test_unpublished_newest_date_falls_back_without_pruning_oldest(self):
        self.seed(["2026-11-15", "2026-11-16", "2026-11-17"])
        with self.patched_paths(), \
             patch.object(updater, "MIN_VALID_DOMAINS", 1), \
             patch.object(updater, "datetime", self.FixedDateTime), \
             patch.object(updater, "load_settings", return_value=(3, set())), \
             patch.object(updater, "download_day", side_effect=updater.ArchiveUnavailable("not published")):
            result = updater.update_local_store()
        self.assertFalse((self.daily / "2026-11-18.txt").exists())
        self.assertTrue((self.daily / "2026-11-15.txt").exists())
        self.assertTrue((self.daily / "2026-11-16.txt").exists())
        self.assertTrue((self.daily / "2026-11-17.txt").exists())
        self.assertTrue(result[3])  # First-ever aggregate must be generated.

    def test_existing_latest_archive_is_not_downloaded_again(self):
        self.seed(["2026-11-16", "2026-11-17", "2026-11-18"])
        with self.patched_paths(), \
             patch.object(updater, "MIN_VALID_DOMAINS", 1), \
             patch.object(updater, "datetime", self.FixedDateTime), \
             patch.object(updater, "load_settings", return_value=(3, set())), \
             patch.object(updater, "download_day", side_effect=AssertionError("should not download an existing file")):
            result = updater.update_local_store()
        self.assertTrue(result[3])  # First-ever aggregate must be generated.

    def test_new_feed_fetches_only_newest_and_does_not_redownload_older_dates(self):
        self.seed(["2026-11-16", "2026-11-17"])
        with self.patched_paths(), \
             patch.object(updater, "MIN_VALID_DOMAINS", 1), \
             patch.object(updater, "datetime", self.FixedDateTime), \
             patch.object(updater, "load_settings", return_value=(3, set())), \
             patch.object(updater, "download_day", return_value={"latest.example"}) as download:
            result = updater.update_local_store()
        self.assertTrue(result[3])
        self.assertEqual(download.call_count, 1)
        download.assert_called_once_with(date(2026, 11, 18))


class UnboundIngestionTests(BasePluginTest):
    def setUp(self):
        super().setUp()
        self.cache_dir = self.root / "bl_cache"
        self.cache_dir.mkdir()
        self.dnsbl_json = self.root / "dnsbl.json"
        self.dnsbl_json.write_text('{"data":{"old.example":[]}}')
        self.feed_url = "http://127.0.0.1:18765/test-nrd.txt"
        self.output.write_text("example.com\n*.example.com\n")
        self.run_state.write_text(json.dumps({
            "status_snapshot": {
                "stats_available": True,
                "published_entries": 2,
                "wildcard_entries": 1,
            }
        }))
        import hashlib
        self.cache_file = self.cache_dir / hashlib.md5(self.feed_url.encode()).hexdigest()

    def patched_refresh_paths(self):
        stack = self.patched_paths()
        stack.enter_context(patch.object(updater, "LOCAL_FEED_URL", self.feed_url))
        stack.enter_context(patch.object(updater, "UNBOUND_URL_CACHE_DIR", self.cache_dir))
        stack.enter_context(patch.object(updater, "UNBOUND_DNSBL_FILE", self.dnsbl_json))
        stack.enter_context(patch.object(updater, "CONFIGCTL", "/bin/true"))
        stack.enter_context(patch.object(updater, "ensure_local_server"))
        return stack

    def test_force_refresh_invalidates_only_feed_cache_and_verifies_ingestion(self):
        self.cache_file.write_text("stale.example\n")
        unrelated_cache = self.cache_dir / "another-blocklist-cache"
        unrelated_cache.write_text("leave-me-alone\n")

        def fake_configctl(*_args, **_kwargs):
            self.assertFalse(self.cache_file.exists(), "NRD cache must be removed before configctl runs")
            self.assertTrue(unrelated_cache.exists(), "other DNSBL caches must be preserved")
            self.cache_file.write_bytes(self.output.read_bytes())
            new_db = self.dnsbl_json.with_suffix(".json.new")
            new_db.write_text('{"data":{"example.com":[]},"config":{"general":{}}}')
            new_db.replace(self.dnsbl_json)
            import subprocess
            return subprocess.CompletedProcess(["configctl", "unbound", "dnsbl"], 0, "OK\n")

        with self.patched_refresh_paths(), patch.object(updater.subprocess, "run", side_effect=fake_configctl):
            self.assertTrue(updater.refresh_unbound(force_fetch=True))
            self.assertEqual(updater._count_file_lines(self.cache_file), 2)
            self.assertTrue(unrelated_cache.exists())
            state = json.loads(self.run_state.read_text())
            self.assertEqual(state["unbound_ingest_status"], "verified")
            self.assertEqual(state["unbound_ingested_output_signature"], updater.file_signature(self.output))
            self.assertTrue(state.get("last_unbound_ingest_utc"))
            self.assertFalse(updater.unbound_refresh_required())

    def test_incomplete_cache_is_not_marked_as_ingested(self):
        def fake_configctl(*_args, **_kwargs):
            self.cache_file.write_text("example.com\n")
            new_db = self.dnsbl_json.with_suffix(".json.new")
            new_db.write_text('{"data":{},"config":{"general":{}}}')
            new_db.replace(self.dnsbl_json)
            import subprocess
            return subprocess.CompletedProcess(["configctl", "unbound", "dnsbl"], 0, "OK\n")

        with self.patched_refresh_paths(), patch.object(updater.subprocess, "run", side_effect=fake_configctl):
            with self.assertRaisesRegex(RuntimeError, "cached 1 NRD lines, expected 2"):
                updater.refresh_unbound(force_fetch=True)
            state = json.loads(self.run_state.read_text())
            self.assertEqual(state["unbound_ingest_status"], "failed")
            self.assertTrue(updater.unbound_refresh_required())

    def test_database_must_be_replaced_after_cache_download(self):
        def fake_configctl(*_args, **_kwargs):
            self.cache_file.write_bytes(self.output.read_bytes())
            import subprocess
            return subprocess.CompletedProcess(["configctl", "unbound", "dnsbl"], 0, "OK\n")

        with self.patched_refresh_paths(), patch.object(updater.subprocess, "run", side_effect=fake_configctl):
            with self.assertRaisesRegex(RuntimeError, "dnsbl.json was not replaced"):
                updater.refresh_unbound(force_fetch=True)
            state = json.loads(self.run_state.read_text())
            self.assertEqual(state["unbound_ingest_status"], "failed")

    def test_no_refresh_leaves_ingestion_pending_for_retry(self):
        with self.patched_refresh_paths():
            self.assertFalse(updater.refresh_unbound(no_refresh=True, force_fetch=True))
            state = json.loads(self.run_state.read_text())
            self.assertEqual(state["unbound_ingest_status"], "pending")
            self.assertTrue(updater.unbound_refresh_required())

    def test_missing_cache_or_failed_status_requires_retry(self):
        with self.patched_refresh_paths():
            state = json.loads(self.run_state.read_text())
            state["unbound_ingest_status"] = "verified"
            state["unbound_ingested_output_signature"] = updater.file_signature(self.output)
            updater.update_run_state(**state)
            self.assertTrue(updater.unbound_refresh_required())
            self.cache_file.write_text("example.com\n*.example.com\n")
            self.assertFalse(updater.unbound_refresh_required())
            updater.update_run_state(unbound_ingest_status="failed")
            self.assertTrue(updater.unbound_refresh_required())


if __name__ == "__main__":
    unittest.main()
