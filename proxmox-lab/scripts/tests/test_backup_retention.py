"""Run with python3 -B -m unittest discover -s tests. No host tools are executed."""
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("retention", Path(__file__).resolve().parents[1] / "backup-retention.py")
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


class WalTests(unittest.TestCase):
    def test_segment_name_matches_postgres_naming(self):
        self.assertEqual("000000010000000000000012", retention.segment_name(1, "0/12000028"))
        self.assertEqual("0000000200000001000000A0", retention.segment_name(2, "1/A0000000"))
        self.assertEqual("000000010000000200000000", retention.segment_name(1, "2/0"))

    def test_base_start_uses_the_lowest_range(self):
        manifest = {"WAL-Ranges": [{"Timeline": 2, "Start-LSN": "0/30000000", "End-LSN": "0/31000000"},
                                   {"Timeline": 1, "Start-LSN": "0/2A000028", "End-LSN": "0/30000000"}]}
        self.assertEqual("00000001000000000000002A", retention.base_start_segment(manifest))

    def test_prune_keeps_the_cutoff_later_files_and_history(self):
        names = ["000000010000000000000010.zst", "000000010000000000000011.partial.zst",
                 "000000010000000000000011.00000028.backup.zst", "000000010000000000000012.zst",
                 "000000020000000000000013.zst", "00000002.history.zst", "cron.log", "x.zst.diverged-1"]
        pruned = list(retention.wal_prune(names, "000000010000000000000012"))
        self.assertEqual(["000000010000000000000010.zst", "000000010000000000000011.partial.zst",
                          "000000010000000000000011.00000028.backup.zst"], pruned)

    def test_prune_ignores_the_timeline_like_pg_archivecleanup(self):
        self.assertEqual(["000000010000000000000011.zst"],
                         list(retention.wal_prune(["000000010000000000000011.zst"], "000000020000000000000012")))

    def test_prune_refuses_a_cutoff_that_is_not_a_wal_name(self):
        with self.assertRaises(ValueError):
            list(retention.wal_prune(["000000010000000000000011.zst"], ""))


class RetentionTests(unittest.TestCase):
    def test_vzdump_keeps_newest_per_vm_and_takes_siblings(self):
        names = ["vzdump-qemu-1022-2026_04_01-04_15_00.vma.zst", "vzdump-qemu-1022-2026_04_01-04_15_00.log",
                 "vzdump-qemu-1022-2026_04_01-04_15_00.vma.zst.notes",
                 "vzdump-qemu-1022-2026_07_01-04_15_00.vma.zst", "vzdump-qemu-1022-2026_09_13-08_02_34.vma.zst",
                 "vzdump-qemu-1021-2026_04_01-04_15_00.vma.zst"]
        self.assertEqual(["vzdump-qemu-1022-2026_04_01-04_15_00.vma.zst",
                          "vzdump-qemu-1022-2026_04_01-04_15_00.log",
                          "vzdump-qemu-1022-2026_04_01-04_15_00.vma.zst.notes"],
                         list(retention.vzdump_prune(names, 2)))

    def test_newest_prune_accepts_rclone_directory_listing(self):
        names = ["20260906T004500Z/", "20260913T004500Z/", "20260830T004500Z/", "incoming/"]
        self.assertEqual(["20260830T004500Z"], list(retention.newest_prune(names, 2)))

    def test_older_than(self):
        now = time.mktime(time.strptime("20260913-120000", "%Y%m%d-%H%M%S"))
        names = ["globals_20260801-001501.sql.gz", "waa_ro_app_20260912-001501.dump", "cron.log"]
        self.assertEqual(["globals_20260801-001501.sql.gz"], list(retention.older_than(names, 30, now)))

    def test_newest_age_per_kind(self):
        now = time.mktime(time.strptime("20260913-120000", "%Y%m%d-%H%M%S"))
        vzdumps = ["vzdump-qemu-1022-2026_09_13-08_00_00.vma.zst", "vzdump-qemu-1022-2026_07_01-04_15_00.vma.zst",
                   "vzdump-qemu-1021-2026_09_13-11_00_00.vma.zst"]
        name, hours = retention.newest_age(vzdumps, "vzdump", "1022", now)
        self.assertEqual(("vzdump-qemu-1022-2026_09_13-08_00_00.vma.zst", 4.0), (name, round(hours, 1)))
        self.assertIsNone(retention.newest_age(vzdumps, "vzdump", "1020", now))
        name, _ = retention.newest_age(["20260906T004500Z/", "20260913T004500Z/"], "base", "", now)
        self.assertEqual("20260913T004500Z", name)
        name, hours = retention.newest_age(["pve-config-pve1-20260913-024001.tar.gz",
                                            "pve-config-pve2-20260913-114001.tar.gz"], "stamped", "pve-config-pve1-", now)
        self.assertEqual(("pve-config-pve1-20260913-024001.tar.gz", 9.3), (name, round(hours, 1)))


class CliTests(unittest.TestCase):
    def test_wal_start_reads_a_manifest_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as manifest:
            json.dump({"WAL-Ranges": [{"Timeline": 1, "Start-LSN": "0/12000028", "End-LSN": "0/12000158"}]}, manifest)
        try:
            out = io.StringIO()
            self.assertEqual(0, retention.main(["x", "wal-start", manifest.name], stdout=out))
            self.assertEqual("000000010000000000000012\n", out.getvalue())
        finally:
            os.unlink(manifest.name)

    def test_prune_commands_read_stdin(self):
        out = io.StringIO()
        stdin = io.StringIO("000000010000000000000010.zst\n000000010000000000000013.zst\n")
        self.assertEqual(0, retention.main(["x", "wal-prune", "000000010000000000000012"], stdin=stdin, stdout=out))
        self.assertEqual("000000010000000000000010.zst\n", out.getvalue())

    def test_unknown_command_is_a_usage_error(self):
        self.assertEqual(2, retention.main(["x", "nope"], stdin=io.StringIO(""), stdout=io.StringIO()))


if __name__ == "__main__":
    unittest.main()
