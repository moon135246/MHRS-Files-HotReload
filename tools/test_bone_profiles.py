import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from bone_profiles import BoneProfiles


class BoneProfileWatchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        game = Path(self.temp.name)
        channel = game / "reframework/data/MHRS-Files-HotReload"
        channel.mkdir(parents=True)
        self.watch = BoneProfiles(game, channel)
        self.custom = self.watch.root
        self.custom.mkdir(parents=True)
        self.file = self.custom / "f_arm507.json"
        self.a = b'{"Head_00":{"x":0,"y":1,"z":0}}'
        self.b = self.a.replace(b'"y":1', b'"y":2')
        self.settle()

    def scan(self):
        self.watch.next_scan = 0
        self.watch.poll()

    def settle(self):
        self.scan()
        self.scan()

    def profiles(self):
        return json.loads(self.watch.notice.read_text("utf-8"))["profiles"]

    def test_add_overwrite_with_preserved_time_and_remove(self):
        self.file.write_bytes(self.a)
        stamp = self.file.stat()
        self.scan()
        self.assertEqual(self.profiles(), {})
        self.scan()
        self.assertEqual(self.profiles(), {"f_arm507": hashlib.sha256(self.a).hexdigest()})
        self.file.write_bytes(self.b)
        os.utime(self.file, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.settle()
        self.assertEqual(self.profiles(), {"f_arm507": hashlib.sha256(self.b).hexdigest()})
        self.file.unlink()
        self.scan()
        self.assertIn("f_arm507", self.profiles())
        self.scan()
        self.assertEqual(self.profiles(), {})

    def test_invalid_or_open_copy_preserves_previous_manifest(self):
        self.file.write_bytes(self.a)
        self.settle()
        old = self.profiles()
        for data in (b'{"fra', b'{"Head_00":{"x":0,"y":false,"z":3}}', b'{"J":{"x":1e999,"y":2,"z":3}}'):
            self.file.write_bytes(data)
            self.settle()
            self.assertEqual(self.profiles(), old)
        self.file.write_bytes(self.b)
        with patch("bone_profiles.require_closed_writers", side_effect=PermissionError()):
            self.settle()
            self.assertEqual(self.profiles(), old)
        self.scan()
        self.assertNotEqual(self.profiles(), old)

    def test_only_outfit_profiles_and_whole_directory_rename(self):
        for name in ("readme.json", "m_weapon042.json", "f_helm.json.bak", "f_helm276.json", "m_leg601_a.json"):
            (self.custom / name).write_bytes(self.a)
        self.settle()
        self.assertEqual(set(self.profiles()), {"f_helm276", "m_leg601_a"})
        self.custom.rename(self.custom.with_name("old"))
        self.settle()
        self.assertEqual(self.profiles(), {})

    def test_payload_matches_notice_and_survives_incomplete_copy(self):
        (self.custom / "f_body507.json").write_bytes(self.a)
        self.file.write_bytes(self.a)
        self.settle()
        head = json.loads(self.watch.notice.read_bytes())
        data = json.loads(self.watch.data.read_bytes())
        self.assertEqual({k: data[k] for k in head}, head)
        digest = hashlib.sha256(self.a).hexdigest()
        self.assertEqual(data["values"], {digest: json.loads(self.a)})
        self.assertEqual(head["profiles"], {"f_arm507": digest, "f_body507": digest})
        self.file.write_bytes(b"{")
        self.settle()
        self.assertEqual(json.loads(self.watch.data.read_bytes()), data)
        self.file.unlink()
        self.settle()
        self.assertEqual(json.loads(self.watch.data.read_bytes())["values"], {digest: json.loads(self.a)})
        (self.custom / "f_body507.json").unlink()
        self.settle()
        self.assertEqual(json.loads(self.watch.data.read_bytes())["values"], {})
        self.assertNotEqual(head["session"], BoneProfiles(self.custom, self.watch.data.parent).session)


if __name__ == "__main__":
    unittest.main()
