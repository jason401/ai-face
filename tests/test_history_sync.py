"""Two isolated Macs sharing a filesystem stand-in for iCloud."""
import copy
import datetime
import os
import hashlib
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isolate  # noqa: F401
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "core"))
from aiface import history, history_sync as sync


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cloud = self.root / "CloudDocs/AI Face/history/v1/devices"
        self.cloud.parents[3].mkdir(parents=True)
        self.a, self.b = "a" * 32, "b" * 32
        self.now = time.time()
        for name, value in [("_identity", None), ("_process", None),
                            ("_running", False), ("_status", "off"), ("CLOUD", self.cloud)]:
            p = patch.object(sync, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(history, "FOLDER", self.root / "local/history")
        p.start()
        self.addCleanup(p.stop)

    def payload(self, owner, emotion="happy", cache=None, rows=None):
        rows = [dict(t=self.now, owner="gpt", emotion=emotion, device=owner)] if rows is None else rows
        day = history._day(self.now) + ".jsonl"
        return dict(cloud=str(self.cloud), id=owner, name="Mac",
                    files={day: "".join(json.dumps(e) + "\n" for e in rows)} if rows else {},
                    cache=copy.deepcopy(cache or {}))

    def test_two_macs_repeated_publish_and_local_first(self):
        sync.replicate(self.payload(self.a))
        cache = sync.replicate(self.payload(self.b, "sad"))["cache"]
        self.assertEqual(len(cache[self.a]["events"]), 1)
        a_files = {p.name: p.read_bytes() for p in (self.cloud / self.a).iterdir()}
        sync.replicate(self.payload(self.b, "calm", cache))
        self.assertEqual(a_files, {p.name: p.read_bytes() for p in (self.cloud / self.a).iterdir()})
        sync._identity = dict(id=self.b, imported=True)
        sync.save_json(sync.folder() / "settings.json", dict(enabled=True))
        sync.save_json(sync.folder() / "cache.json", cache)
        history.record("gpt", "sad", self.now + 1)
        # Deliberately include our own iCloud cache too; never double-count it.
        cache[self.b] = dict(name="Mac", events=self.payload(self.b)["files"])
        sync.save_json(sync.folder() / "cache.json", cache)
        self.assertEqual(len(sync.aggregate()), 2)
        self.assertEqual(len(sync.aggregate("local")), 1)
        self.assertEqual(len(sync.aggregate(self.a)), 1)

    def test_missing_checksum_failure_and_manifest_deletion(self):
        sync.replicate(self.payload(self.a))
        cache = sync.replicate(self.payload(self.b))["cache"]
        path = next((self.cloud / self.a).glob("*.jsonl"))
        old_data = path.read_bytes()
        path.unlink()
        result = sync.replicate(self.payload(self.b, cache=cache))
        self.assertEqual(result["cache"], cache)
        # New manifest, but wrong/missing generation data: retain previous cache.
        head_path = self.cloud / self.a / "device.json"
        head = sync.read_json(head_path)
        head["generation"] += 1
        head["files"][path.name] = hashlib.sha256(b"changed").hexdigest()
        sync.save_json(head_path, head)
        path.write_bytes(old_data)
        result = sync.replicate(self.payload(self.b, cache=cache))
        self.assertTrue(result["pending"])
        self.assertEqual(result["cache"], cache)
        head["generation"] += 1
        head["files"] = {}
        sync.save_json(head_path, head)
        result = sync.replicate(self.payload(self.b, cache=cache))
        self.assertEqual(result["cache"][self.a]["events"], [])
        # Delayed old manifests must not resurrect deleted records.
        head["generation"] -= 1
        sync.save_json(head_path, head)
        old = result["cache"]
        self.assertTrue(sync.replicate(self.payload(self.b, cache=old))["pending"])

    def test_migration_keeps_origin_and_authoritative_empty_cache(self):
        with patch.object(sync, "hardware", return_value="old"):
            old = sync.initialize()["id"]
        history.record("gpt", "happy", self.now)
        with patch.object(sync, "hardware", return_value="new"):
            new = sync.initialize()["id"]
        self.assertNotEqual(old, new)
        self.assertFalse(sync.enabled())
        sync.configure(True)
        history.record("claude", "calm", self.now + 1)
        self.assertEqual(len(sync.aggregate()), 2)
        self.assertEqual(sum(len(history.decode_events(v)) for v in sync.snapshot().values()), 1)
        sync.save_json(sync.folder() / "cache.json", {old: dict(name="old", events=[])})
        self.assertEqual(len(sync.aggregate()), 1)
        self.assertEqual(history.clear(), 1)
        self.assertEqual(len(sync.aggregate()), 0)
        # Foreign local origin is preserved, never published by the new Mac.
        self.assertEqual(len(history.events(history._day(self.now))), 1)

    def test_legacy_choice_and_off_deletion(self):
        history.record("gpt", "happy", self.now)
        with patch.object(sync, "hardware", return_value="first"):
            sync.initialize()
        sync.configure(True, import_existing=True)
        self.assertEqual(len(sync.aggregate()), 1)
        sync.configure(False)
        with patch.object(sync.subprocess, "Popen", side_effect=AssertionError("Cloud while OFF")):
            sync.synchronize()
        history.clear()
        sync.configure(True)
        self.assertEqual(sync.snapshot(), {})
        self.assertEqual(sync.aggregate(), [])
        # A second Mac with untagged copied history explicitly skips import.
        history.FOLDER = self.root / "other/history"
        history.FOLDER.mkdir(parents=True)
        (history.FOLDER / (history._day(self.now) + ".jsonl")).write_text(
            json.dumps(dict(t=self.now, owner="gpt", emotion="happy")) + "\n")
        with patch.object(sync, "hardware", return_value="second"):
            sync.initialize()
        sync.configure(True, import_existing=False)
        self.assertEqual(sync.aggregate(), [])
        sync.configure(False)
        self.assertEqual(len(sync.aggregate()), 1)

    def test_worker_roundtrip_and_enable_disable_retry(self):
        with patch.object(sync, "hardware", return_value="mac"):
            sync.initialize()
        sync.configure(True)
        history.record("gpt", "happy", self.now)
        sync.synchronize()  # actual timed subprocess
        self.assertEqual(sync.status()["state"], "ready")
        head = sync.read_json(self.cloud / sync.device_id() / "device.json")
        self.assertEqual(len(head["files"]), 1)
        sync.configure(False)
        history.clear()
        sync.configure(True)
        sync.synchronize()
        self.assertEqual(sync.read_json(self.cloud / sync.device_id() / "device.json")["files"], {})

    def test_timeout_kills_worker_and_keeps_cache(self):
        with patch.object(sync, "hardware", return_value="mac"):
            sync.initialize()
        sync.configure(True)
        original = {self.b: dict(name="B", events=[])}
        sync.save_json(sync.folder() / "cache.json", original)
        child = Mock()
        child.communicate.side_effect = [subprocess.TimeoutExpired("worker", 30), (b"", b"")]
        with patch.object(sync.subprocess, "Popen", return_value=child):
            sync.synchronize()
        child.kill.assert_called_once()
        self.assertEqual(sync.cached(), original)
        self.assertEqual(sync.status()["state"], "waiting")
        self.assertIsNone(sync._process)
        self.assertFalse(sync._running)

    def test_timezone_rebucket_and_retention(self):
        original_tz = os.environ.get("TZ")
        try:
            os.environ["TZ"] = "UTC"
            time.tzset()
            timestamp = datetime.datetime(2026, 11, 7, 0, 30, tzinfo=datetime.timezone.utc).timestamp()
            self.assertEqual(history._day(timestamp), "2026-11-07")
            os.environ["TZ"] = "America/Los_Angeles"
            time.tzset()
            rows = [dict(t=timestamp, owner="gpt", emotion="happy")]
            self.assertEqual(history.period("day", "2026-11-06", [], source=rows)["total"], 1)
            self.assertEqual(history.period("day", "2026-11-07", [], source=rows)["total"], 0)
        finally:
            if original_tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = original_tz
            time.tzset()
        # A source file's date does not determine the date in the viewer's statistics.
        data = [dict(t=self.now, owner="gpt", emotion="happy")]
        key = history._day(self.now)
        self.assertEqual(history.period("day", key, [], source=data)["total"], 1)
        self.assertEqual(history.period("day", "2001-01-01", [], source=data)["total"], 0)
        sync._identity = dict(id=self.a)
        sync.save_json(sync.folder() / "settings.json", dict(enabled=True))
        sync.save_json(sync.folder() / "cache.json", {
            self.b: dict(name="old", events=[dict(t=self.now - 500 * 86400, owner="gpt", emotion="happy")])})
        self.assertEqual(sync.aggregate(), [])

    def test_manifest_validation_and_failed_publish_preserves_head(self):
        sync.replicate(self.payload(self.a))
        path = self.cloud / self.a / "device.json"
        before = path.read_bytes()
        with patch.object(sync, "atomic", side_effect=OSError("offline")):
            with self.assertRaises(OSError):
                sync.replicate(self.payload(self.a, "sad"))
        self.assertEqual(path.read_bytes(), before)
        raw = sync.read_json(path)
        raw["files"] = {"../escape.jsonl": "0" * 64}
        with self.assertRaises(ValueError):
            sync.manifest(raw, self.a)


if __name__ == "__main__":
    unittest.main()
