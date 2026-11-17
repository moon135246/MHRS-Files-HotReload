import ctypes
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from platform_files import PlatformFileConflict, PlatformFiles


class PlatformFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "natives/stm"
        self.state = Path(self.tmp.name) / "state"
        self.manager = PlatformFiles(self.root, self.state)
        self.addCleanup(lambda: self.manager.close())
        self.source = self.root / "player/mod/f/pl279/f_arm279.mdf2.23"
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b"first")
        self.target = Path(str(self.source) + ".stm")

    def restart(self):
        self.manager.lock.close()  # OS closes this handle on an unclean exit
        self.manager = PlatformFiles(self.root, self.state)

    def test_atomic_source_replace_in_place_and_deletion(self):
        self.assertEqual(self.manager.prepare([self.source]), {self.source})
        self.assertTrue(self.target.samefile(self.source))
        self.source.write_bytes(b"saved")
        self.manager.prepare([self.source])
        swap = self.source.with_suffix(".tmp")
        swap.write_bytes(b"fresh")
        os.replace(swap, self.source)
        self.manager.prepare([self.source])
        self.assertEqual(self.target.read_bytes(), b"fresh")
        self.assertTrue(self.target.samefile(self.source))
        self.source.unlink()
        self.assertEqual(self.manager.prepare([self.source]), set())
        self.assertFalse(self.target.exists())

    def test_user_platform_files_are_never_owned(self):
        self.target.write_bytes(b"first")
        self.manager.prepare([self.source])
        self.assertEqual(list(self.manager.state.glob("*.json")), [])
        self.target.write_bytes(b"foreign")
        with self.assertRaisesRegex(PlatformFileConflict, "Existing user platform file"):
            self.manager.prepare([self.source])
        self.restart()
        self.assertEqual(self.target.read_bytes(), b"foreign")

    def test_batch_protects_shared_sources_and_foreign_targets_on_retry(self):
        siblings = [self.source.with_name(f"shared_{i}.tex.28") for i in range(12)]
        for path in siblings:
            os.link(self.source, path)
        foreign = Path(str(siblings[3]) + ".stm")
        foreign.write_bytes(b"other mod")
        with self.assertRaises(PlatformFileConflict):
            self.manager.prepare(siblings)
        self.assertEqual(foreign.read_bytes(), b"other mod")
        foreign.unlink()
        self.assertEqual(self.manager.prepare(siblings), set(siblings))
        for path in siblings:
            self.assertTrue(Path(str(path) + ".stm").samefile(path))
        self.restart()
        self.assertTrue(all(path.read_bytes() == b"first" for path in siblings))
        self.assertFalse(any(Path(str(path) + ".stm").exists() for path in siblings))

    def test_replaced_source_during_link_publication_is_retried(self):
        swap = self.source.with_name("replacement")
        swap.write_bytes(b"new")
        link = os.link

        def publish_replacement(source, payload):
            link(source, payload)
            source.rename(source.with_name("previous"))
            swap.rename(source)

        with patch("platform_files.os.link", side_effect=publish_replacement):
            with self.assertRaisesRegex(OSError, "Source was replaced"):
                self.manager.prepare([self.source])
        self.assertFalse(self.target.exists())
        self.assertEqual(self.manager.prepare([self.source]), {self.source})
        self.assertEqual(self.target.read_bytes(), b"new")

    def test_rename_of_old_source_during_final_publish_and_pak_reinstall(self):
        replacement = self.source.with_name("replacement")
        replacement.write_bytes(b"new mod")
        original = os.rename

        def swap_at_publish(src, dst):
            if dst == self.target:
                original(self.source, self.source.with_name("previous"))
                original(replacement, self.source)
            return original(src, dst)

        with patch("platform_files.os.rename", side_effect=swap_at_publish):
            with self.assertRaisesRegex(OSError, "Source was replaced"):
                self.manager.prepare([self.source])
        self.assertEqual(self.manager.prepare([self.source]), {self.source})
        self.assertTrue(self.target.samefile(self.source))
        self.assertEqual(self.target.read_bytes(), b"new mod")

        self.source.unlink()
        package = self.state / "packaged"
        package.write_bytes(b"stock")

        def reinstall_at_publish(src, dst):
            if dst == self.target:
                self.source.write_bytes(b"reinstalled")
            return original(src, dst)

        with patch("platform_files.os.rename", side_effect=reinstall_at_publish):
            with self.assertRaisesRegex(OSError, "Mod was reinstalled"):
                self.manager.prepare_from_package({self.source: package})
        self.assertEqual(self.manager.prepare_from_package({self.source: package}), {self.source})
        self.assertTrue(self.target.samefile(self.source))
        self.assertEqual(self.target.read_bytes(), b"reinstalled")
        self.assertEqual(package.read_bytes(), b"stock")

    def test_unchanged_owned_hardlink_skips_hash_and_preserved_mtime_edit_is_seen(self):
        self.manager.prepare([self.source])
        with patch("platform_files._digest", side_effect=AssertionError("unexpected full read")):
            self.assertEqual(self.manager.prepare([self.source]), {self.source})
        before = self.source.stat()
        self.source.write_bytes(b"other")
        os.utime(self.source, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.manager.prepare([self.source])
        journal, = self.manager.state.glob("*.json")
        record = json.loads(journal.read_text(encoding="utf-8"))
        self.assertEqual(record["owner"]["sha256"], hashlib.sha256(b"other").hexdigest())
        with patch("platform_files._digest", side_effect=AssertionError("unexpected full read")):
            self.manager.prepare([self.source])

    def test_user_atomic_replacement_with_identical_content_survives_recovery(self):
        self.manager.prepare([self.source])
        user = self.target.with_suffix(".mine")
        user.write_bytes(b"first")
        os.replace(user, self.target)
        self.restart()
        self.assertTrue(self.target.exists())
        self.assertFalse(self.target.samefile(self.source))

    def test_copy_fallback_detects_same_file_edited_by_someone_else(self):
        with patch("platform_files.os.link", side_effect=ctypes.WinError(50)):
            self.manager.prepare([self.source])
            self.assertFalse(self.target.samefile(self.source))
            self.source.write_bytes(b"second")
            self.manager.prepare([self.source])
            self.assertEqual(self.target.read_bytes(), b"second")
            self.target.write_bytes(b"user-edited")
            with self.assertRaises(PlatformFileConflict):
                self.manager.prepare([self.source])
            self.restart()
            self.assertEqual(self.target.read_bytes(), b"user-edited")

    def test_interrupted_publication_before_and_after_rename(self):
        with patch("platform_files.os.rename", side_effect=OSError("interrupted")):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.manager.prepare([self.source])
        self.target.write_bytes(b"user")
        self.restart()
        self.assertEqual(self.target.read_bytes(), b"user")
        self.target.unlink()
        save = self.manager._save

        def crash_after_rename(journal, record):
            if "stage" not in record:
                raise OSError("lost final receipt")
            save(journal, record)

        with patch.object(self.manager, "_save", side_effect=crash_after_rename):
            with self.assertRaisesRegex(OSError, "lost final receipt"):
                self.manager.prepare([self.source])
        self.assertTrue(self.target.samefile(self.source))
        self.restart()
        self.assertFalse(self.target.exists())
        self.assertFalse(list(self.source.parent.glob(".mhrs-platform-*")))

    def test_readonly_source_retains_its_attributes(self):
        self.source.chmod(stat.S_IREAD)
        try:
            self.manager.prepare([self.source])
            self.manager.close()
            self.assertFalse(self.target.exists())
            self.assertTrue(self.source.stat().st_file_attributes & stat.FILE_ATTRIBUTE_READONLY)
        finally:
            self.source.chmod(stat.S_IWRITE)

    def test_custom_streamed_texture_scope_and_single_owner(self):
        with self.assertRaises(OSError):
            PlatformFiles(self.root, self.state)
        texture = self.root / "streaming/custom/generic.tex.28"
        texture.parent.mkdir(parents=True)
        texture.write_bytes(b"texture")
        ignored = self.root / "custom/unrelated.mesh.2109148288"
        self.assertEqual(self.manager.prepare([texture, ignored]), {texture})
        self.assertTrue(Path(str(texture) + ".stm").samefile(texture))
        journal, = self.manager.state.glob("*.json")
        record = json.loads(journal.read_text(encoding="utf-8"))
        self.assertEqual(len(record["owner"]["sha256"]), 64)

    def test_equipment_chain_and_user_files_and_scope(self):
        for suffix in (".chain.48", ".user.2"):
            armor = self.source.parent / ("f_arm279" + suffix)
            armor.write_bytes(b"A")
            other = self.root / ("systems/data" + suffix)
            self.assertEqual(self.manager.prepare([armor, other]), {armor})
            side = Path(str(armor) + ".stm")
            self.assertTrue(side.samefile(armor))
            swap = armor.with_name("replacement")
            swap.write_bytes(b"B")
            os.replace(swap, armor)
            self.manager.prepare([armor])
            self.assertEqual(side.read_bytes(), b"B")
            armor.unlink()
            self.manager.prepare([armor])
            self.assertFalse(side.exists())

    def test_packaged_fallback_reinstall_and_repeated_uninstall(self):
        package = self.state / "extracted.mdf2.23"
        package.write_bytes(b"packed")
        self.source.unlink()
        self.source.parent.rmdir()
        mapping = {self.source: package}
        for _ in range(2):
            self.assertEqual(self.manager.prepare_from_package(mapping), {self.source})
            self.assertFalse(self.source.exists())
            self.assertFalse(self.target.samefile(package))
            self.assertEqual(self.target.read_bytes(), b"packed")
            self.source.write_bytes(b"mod")
            self.manager.prepare_from_package(mapping)
            self.assertTrue(self.target.samefile(self.source))
            self.assertEqual(self.target.read_bytes(), b"mod")
            self.source.unlink()
        self.manager.prepare_from_package(mapping)
        package.unlink()  # Crash recovery does not need the extracted data.
        self.restart()
        self.assertFalse(self.target.exists())
        self.assertFalse(self.source.exists())

    def test_packaged_conflicts_preserve_user_files_and_private_original(self):
        package = self.state / "original"
        package.write_bytes(b"packed")
        self.source.unlink()
        mapping = {self.source: package}
        self.target.write_bytes(b"user")
        with self.assertRaisesRegex(PlatformFileConflict, "Existing user platform"):
            self.manager.prepare_from_package(mapping)
        self.assertEqual(self.target.read_bytes(), b"user")
        self.target.write_bytes(b"packed")
        self.manager.prepare_from_package(mapping)
        self.manager.discard([self.source])
        self.assertEqual(self.target.read_bytes(), b"packed")
        self.target.unlink()
        self.manager.prepare_from_package(mapping)
        self.target.write_bytes(b"user edit")
        self.assertEqual(package.read_bytes(), b"packed")
        self.manager.discard([self.source])
        self.assertEqual(self.target.read_bytes(), b"user edit")

    def test_discard_startup_header_keeps_source_and_identical_user_replacement(self):
        self.manager.prepare([self.source])
        self.manager.discard([self.source, self.source])
        self.assertFalse(self.target.exists())
        self.assertEqual(self.source.read_bytes(), b"first")
        self.manager.prepare([self.source])
        replacement = self.target.with_suffix(".other")
        replacement.write_bytes(b"first")
        os.replace(replacement, self.target)
        self.manager.discard([self.source])
        self.assertTrue(self.target.exists())
        self.assertFalse(self.target.samefile(self.source))
        self.assertFalse(list(self.manager.state.glob("*.json")))

    def test_missing_or_unverified_package_keeps_previous_binding(self):
        self.manager.prepare([self.source])
        self.source.unlink()
        package = self.state / "original"
        with self.assertRaises(FileNotFoundError):
            self.manager.prepare_from_package({self.source: package})
        self.assertEqual(self.target.read_bytes(), b"first")
        package.write_bytes(b"packed")
        with patch("platform_files.shutil.copyfileobj", return_value=None):
            with self.assertRaisesRegex(OSError, "Source changed while staging"):
                self.manager.prepare_from_package({self.source: package})
        self.assertEqual(self.target.read_bytes(), b"first")
        self.manager.prepare_from_package({self.source: package})
        self.assertEqual(self.target.read_bytes(), b"packed")


if __name__ == "__main__":
    unittest.main()
