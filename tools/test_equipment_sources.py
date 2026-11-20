import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from equipment_physics import physics_expectations
from equipment_sources import EquipmentSources
from platform_files import PlatformFiles
from resource_links import logical_path


class Archive:
    def __init__(self):
        self.files = {}
        self.requests = []

    def read(self, relative):
        self.requests.append(relative)
        return self.files.get(relative)

    def extract(self, relative, dest):
        data = self.read(relative)
        if data is None:
            return False
        dest.write_bytes(data)
        return True


class EquipmentSourcesTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "natives/stm"
        self.platform = PlatformFiles(self.root, Path(tmp.name) / "state")
        self.addCleanup(self.platform.close)
        self.archive = Archive()
        self.mdf = "player/mod/f/pl279/f_arm279.mdf2"
        self.links = SimpleNamespace(graph={}, stock_parents={})
        self.previous = SimpleNamespace(graph={})

    def write(self, name, data):
        f = self.root / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(data)
        return f

    def prepare(self, sources, files, current, affected, **options):
        paths = {f: logical_path(self.root, f).lower() for f in files}
        targets = set(paths.values())
        targets.update(p.removeprefix("streaming/") for p in paths.values())
        known = {logical_path(self.root, f): f for f in current}
        return sources.prepare(paths, current, affected | targets, targets, self.links, self.previous, {}, known, **options)

    def test_texture_overwrite_keeps_unchanged_sibling_generations(self):
        albedo = self.write("player/mod/demo/albedo.tex.28", b"updated")
        detail = self.write("player/mod/demo/detail.tex.28", b"same")
        owner = self.write(self.mdf + ".23", b"material")
        self.links.graph[self.mdf] = {"player/mod/demo/albedo.tex", "player/mod/demo/detail.tex"}
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        current = {albedo: (2, 1), detail: (1, 0), owner: (1, 0)}
        selected, ready, _ = self.prepare(sources, {albedo}, current, {self.mdf}, texture_edits=True)
        self.assertEqual(selected, {albedo, owner})
        self.assertEqual(ready, selected)
        self.assertFalse(Path(str(detail) + ".stm").exists())

    def test_startup_positive_cache_removal_pak_then_reinstall(self):
        file = self.write(self.mdf + ".23", b"boot mod")
        sources = EquipmentSources(self.root, self.platform, self.archive, {file: (1, 0)})
        self.archive.files[file.relative_to(self.root)] = b"original"
        file.unlink()
        _, ready, keys = self.prepare(sources, {file}, {}, {self.mdf})
        self.assertEqual((ready, keys), ({file}, [self.mdf]))
        self.assertEqual(sources.original(file), b"original")
        self.assertFalse(file.exists())
        self.write(self.mdf + ".23", b"reinstalled")
        self.prepare(sources, {file}, {file: (2, 1)}, {self.mdf})
        self.assertNotIn(file, sources.packaged)
        self.assertEqual(Path(str(file)+".stm").read_bytes(), b"reinstalled")

    def test_vertex_proof_pins_the_platform_file_and_leaves_mod_manager_writes_free(self):
        name = "player/mod/f/pl279/f_leg279.mesh.2109148288"
        file = self.write(name, b"first model")
        target = Path(str(file) + ".stm")
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        self.platform.prepare([file])
        self.assertTrue(target.samefile(file))
        # After staging, an installer assigns a different inode to the same
        # ordinary name. The read handed to vertex_edit must be exactly the
        # bytes the renderer will request, including while the next mod lands.
        swap = file.with_suffix(".swap")
        swap.write_bytes(b"second model")
        os.replace(swap, file)
        with sources.vertex_source(file, b"stock", True) as held:
            self.assertEqual(held.read(), target.read_bytes())
            self.assertEqual(target.read_bytes(), b"second model")
            self.assertFalse(target.samefile(file))
            file.write_bytes(b"third model")
            swap.write_bytes(b"fourth model")
            os.replace(swap, file)
            with self.assertRaises(OSError):
                target.write_bytes(b"different")
            with self.assertRaises(OSError):
                target.rename(target.with_suffix(".other"))
            self.assertEqual(target.read_bytes(), b"second model")
        self.platform.prepare([file])
        self.assertEqual(target.read_bytes(), b"fourth model")

        file.unlink()
        self.platform.prepare([file])
        with sources.vertex_source(file, b"stock", False) as held:
            self.assertEqual(held.read(), b"stock")
            self.assertIn(file, sources.packaged)
            file.write_bytes(b"reinstalled during removal")
            self.assertEqual(target.read_bytes(), b"stock")
        self.platform.prepare([file])
        self.assertEqual(target.read_bytes(), b"reinstalled during removal")

    def test_vertex_source_preserves_and_never_locks_a_foreign_alias(self):
        file = self.write("player/mod/f/pl279/f_leg279.mesh.2109148288", b"vertex mod")
        target = Path(str(file) + ".stm")
        target.write_bytes(b"vertex mod")
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        self.platform.prepare([file])
        with sources.vertex_source(file, b"stock", True) as held:
            self.assertIsNone(held)
            target.write_bytes(b"other mod")
        file.unlink()
        with sources.vertex_source(file, b"stock", False) as held:
            self.assertIsNone(held)
            target.rename(target.with_suffix(".other"))
        self.assertFalse(sources.staged)

    def test_stock_proof_transfers_once_and_reuses_only_verified_owned_pak_bytes(self):
        name = "player/mod/f/pl279/f_leg279.mesh.2109148288"
        file = self.root / name
        target = Path(str(file) + ".stm")
        self.archive.files[file.relative_to(self.root)] = b"original PAK"
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        with patch("platform_files.shutil.copyfileobj", side_effect=AssertionError("copied PAK extract twice")):
            with sources.stock_mesh_source(file) as first:
                self.assertEqual(first.read(), b"original PAK")
                first_id = os.fstat(first.fileno()).st_ino
                with self.assertRaises(OSError):
                    target.write_bytes(b"late writer")
            with sources.stock_mesh_source(file) as reused:
                self.assertEqual(os.fstat(reused.fileno()).st_ino, first_id)
                self.assertEqual(reused.read(), b"original PAK")
        self.assertEqual(self.archive.requests, [file.relative_to(self.root)])
        target.write_bytes(b"modified externally")
        with sources.stock_mesh_source(file) as changed:
            self.assertIsNone(changed)
            target.write_bytes(b"third-party bytes")
        target.rename(target.with_suffix(".saved"))
        target.write_bytes(b"original PAK")
        with sources.stock_mesh_source(file) as foreign:
            self.assertIsNone(foreign)
            target.write_bytes(b"owner can replace")
        self.assertEqual(target.read_bytes(), b"owner can replace")

    def test_cold_install_removal_uses_packaged_helmet_without_a_platform_copy(self):
        file = self.root / "player/mod/f/pl279/f_helm279.user.2"
        self.archive.files[file.relative_to(self.root)] = b"stock helmet"
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        self.assertEqual(sources.original(file), b"stock helmet")
        self.assertFalse(Path(str(file) + ".stm").exists())
        self.assertIsNone(sources.original(self.root / "player/mod/f/pl701/f_helm701.user.2"))

    def test_external_helmet_fields_defer_but_invalid_user_still_fails(self):
        key = "player/mod/f/pl279/f_helm279.user"
        file = self.write(key + ".2", b"USR\0\x01" + bytes(35))
        spec = physics_expectations({file: key}, {file}, None)
        self.assertEqual(spec["helmets"][key], {"removed": False, "deferred": True})
        file.write_bytes(b"partial copy")
        with self.assertRaisesRegex(ValueError, "Invalid USER header"):
            physics_expectations({file: key}, {file}, None)

    def test_stage_motion_add_and_delete_from_cold_start(self):
        motion = "stage/v01/a00/mod/v01a00_suisha01.mot"
        file = self.write(motion + ".495", b"reversed rotation")
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        selected, ready, names = self.prepare(sources, {file}, {file:(1, 1)}, {motion})
        self.assertEqual((selected, ready, names), ({file}, {file}, [motion]))
        alias = Path(str(file) + ".stm")
        self.assertEqual(alias.read_bytes(), b"reversed rotation")
        file.unlink()
        self.prepare(sources, {file}, {}, {motion})
        self.assertFalse(alias.exists())

    def test_startup_loose_motion_uninstall_reopens_packaged_generation(self):
        motion = "stage/v01/a00/mod/v01a00_suisha01.mot"
        file = self.write(motion + ".495", b"preinstalled")
        self.archive.files[file.relative_to(self.root)] = b"packaged"
        sources = EquipmentSources(self.root, self.platform, self.archive, {file:(1, 1)})
        file.unlink()
        _, ready, names = self.prepare(sources, {file}, {}, {motion})
        self.assertEqual((ready, names), ({file}, [motion]))
        self.assertEqual(Path(str(file) + ".stm").read_bytes(), b"packaged")

    def test_streaming_only_shared_tex_uses_pak_header_then_drops_it(self):
        path = "shared/skin.tex"
        stream = self.write("streaming/" + path + ".28", b"loose mips")
        header = self.root / (path + ".28")
        self.archive.files[header.relative_to(self.root)] = b"PAK header"
        self.links.graph[self.mdf] = {path}
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        _, ready, names = self.prepare(sources, {stream}, {stream: (1, 0)}, {self.mdf})
        self.assertEqual((ready, names), ({header, stream}, [path]))
        self.assertEqual(Path(str(header)+".stm").read_bytes(), b"PAK header")
        stream.unlink()
        self.prepare(sources, {stream}, {}, {self.mdf})
        self.assertFalse(Path(str(header)+".stm").exists())
        self.assertFalse(Path(str(stream)+".stm").exists())
        self.assertFalse(sources.packaged)

    def test_single_nonplayer_texture_with_packaged_equipment_parent(self):
        path = "shared/albedo.tex"
        file = self.write(path + ".28", b"new diffuse")
        self.links.stock_parents[path] = {self.mdf}
        sources = EquipmentSources(self.root, self.platform, self.archive, {})
        _, ready, names = self.prepare(sources, {file}, {file: (1, 0)}, {self.mdf})
        self.assertEqual((ready, names), ({file}, [path]))
        self.assertFalse(self.archive.requests)

    def test_unchanged_shared_startup_texture_is_not_republished(self):
        path = "shared/albedo.tex"
        file = self.write(path + ".28", b"existing diffuse")
        current = {file: ((1, 1, 1), 0)}
        self.links.graph[self.mdf] = {path}
        sources = EquipmentSources(self.root, self.platform, self.archive, current)
        selected, ready, _ = self.prepare(sources, set(), current, {self.mdf})
        self.assertFalse(selected)
        self.assertFalse(ready)


if __name__ == "__main__":
    unittest.main()
