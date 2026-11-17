"""Exercise the Windows save patterns and parent references used by the watcher."""
import os
import ctypes
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from file_changes import require_closed_writers, snapshots
from platform_files import PlatformFiles
from material_layout import IncompatibleMaterial, Material, MaterialValidator, check_layout
from resource_links import ResourceLinks, consumers, logical_path
from watch_arm279 import command, replace
from watch_outfit import GuiReadyNotice, SUFFIXES, files, signature


class FileChangesTest(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "requires Windows filesystem metadata")
    def test_unsupported_directory_notifications_use_bounded_metadata_scans(self):
        with tempfile.TemporaryDirectory() as tmp:
            game = Path(tmp)
            root = game / "natives/stm"
            root.mkdir(parents=True)
            path = root / "part.chain.48"
            path.write_bytes(b"abc")
            scans = []

            def counted(directory):
                scans.append(directory)
                return files(directory)

            with patch("file_changes.DirectoryChanges", side_effect=OSError("unsupported")), \
                    patch("file_changes.POLL_INTERVAL", .08):
                stream = snapshots(root, counted, signature, SUFFIXES, anchor=game)
                try:
                    before = next(stream)
                    for _ in range(3):
                        self.assertIs(stream.send(0), before)
                    self.assertEqual(len(scans), 1)
                    stat = path.stat()
                    # NTFS can timestamp both operations with the same clock
                    # tick. Exercise a distinct post-startup physical write.
                    time.sleep(.03)
                    path.write_bytes(b"xyz")
                    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                    self.assertEqual(signature(path), before[path][0])
                    end = time.monotonic() + 2
                    while stream.send(.03) is before:
                        self.assertLess(time.monotonic(), end, "missed unchanged LastWriteTime")
                    path.unlink()
                    end = time.monotonic() + 2
                    while path in stream.send(.03):
                        self.assertLess(time.monotonic(), end, "missed removal during polling")
                finally:
                    stream.close()

    def test_contending_command_resumes_when_channel_is_released(self):
        import msvcrt
        with tempfile.TemporaryDirectory() as directory, ThreadPoolExecutor(1) as pool:
            channel = Path(directory)
            attempted = threading.Event()
            original = msvcrt.locking
            def tracked_lock(fd, mode, size):
                try:
                    return original(fd, mode, size)
                except OSError:
                    attempted.set()
                    raise
            with (channel / "channel.lock").open("a+b") as lock:
                original(lock.fileno(), msvcrt.LK_NBLCK, 1)
                with patch("watch_arm279.msvcrt.locking", side_effect=tracked_lock), patch("watch_arm279.exchange", return_value="ready"):
                    future = pool.submit(command, channel, "inspect")
                    try:
                        self.assertTrue(attempted.wait(2))
                    finally:
                        original(lock.fileno(), msvcrt.LK_UNLCK, 1)
                    self.assertEqual(future.result(timeout=.8), "ready")

    def test_gui_notifies_only_on_readiness_and_renews_after_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            channel = Path(directory)
            notice = GuiReadyNotice(channel)
            owners = {"sample.uvs": ["sample.gui"]}
            try:
                self.assertTrue(notice.due(owners))
                notice.acknowledge(owners, [], True)
                (channel / "status.json").write_text("unrelated")
                time.sleep(.02)
                self.assertFalse(notice.due(owners))
                for state in ("loaded", "ready"):
                    replace(notice.path, json.dumps({"state": state}).encode())
                    end = time.monotonic() + 2
                    while not notice.due(owners):
                        self.assertLess(time.monotonic(), end)
                        time.sleep(.005)
                    self.assertTrue(notice.due(owners))  # an unacknowledged signal is retried
                    notice.acknowledge(owners, list(owners) if state == "ready" else [], True)
                self.assertFalse(notice.due({}))
                self.assertIsNone(notice.watch)
                with patch("watch_outfit.DirectoryChanges", side_effect=OSError("unavailable")):
                    self.assertTrue(notice.due(owners))
                    notice.acknowledge(owners, [], False)
                    self.assertLessEqual(notice.renew_at - time.monotonic(), 1)
                    self.assertTrue(notice.due({}))
            finally:
                notice.close()

    def test_reply_wait_handles_a_partial_reply_and_notification_failure(self):
        def respond(channel):
            request = channel / "request.json"
            deadline = time.monotonic() + 4
            while not request.is_file():
                if time.monotonic() >= deadline:
                    raise TimeoutError("Request was not published")
                time.sleep(.002)
            req = json.loads(request.read_bytes())
            status = channel / "status.json"
            status.write_bytes(b"{")
            time.sleep(.02)
            replace(status, json.dumps({"id": req["id"], "ok": True, "result": req["action"]}).encode())
        for fallback in (False, True):
            with self.subTest(fallback=fallback), tempfile.TemporaryDirectory() as directory, ThreadPoolExecutor(1) as pool:
                channel = Path(directory)
                (channel / "status.json").write_text('{"id":"old","ok":false}')
                response = pool.submit(respond, channel)
                if fallback:
                    with patch("watch_arm279.DirectoryChanges", side_effect=OSError("unavailable")):
                        result = command(channel, "inspect")
                else:
                    result = command(channel, "inspect")
                response.result()
                self.assertEqual(result, "inspect")

    @unittest.skipUnless(os.name == "nt", "requires Windows directory notifications")
    def test_supported_filename_becomes_directory_and_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "stm"
            root.mkdir()
            target = root / "group.user.2"
            child = target / "inner.user.2"
            target.write_bytes(b"outer")
            stream = snapshots(root, files, signature, SUFFIXES)
            def wait_for(expected):
                limit = time.monotonic() + 2
                while set(stream.send(.1)) != expected:
                    self.assertLess(time.monotonic(), limit)
            try:
                self.assertEqual(set(next(stream)), {target})
                target.unlink()
                target.mkdir()
                child.write_bytes(b"inner")
                wait_for({child})
                child.unlink()
                target.rmdir()
                target.write_bytes(b"outer again")
                wait_for({target})
            finally:
                stream.close()

    def test_index_keeps_variants_spelling_and_packaged_fallback(self):
        def reference(name):
            return (name + "\0").encode("utf-16-le")
        with tempfile.TemporaryDirectory() as directory:
            root, stock = Path(directory) / "loose", Path(directory) / "stock"
            root.mkdir()
            stock.mkdir()
            main = root / "Hud.uvs.7"
            platform = root / "Hud.uvs.7.stm"
            (stock / main.name).write_bytes(reference("Tex/Stock.tex"))
            links = ResourceLinks(stock)
            main.write_bytes(reference("Tex/Icon.tex"))
            platform.write_bytes(reference("TEX/ICON.tex"))
            links.update(root, {main: 1, platform: 1})
            first = links.index
            self.assertEqual(links.aliases["tex/icon.tex"], {"Tex/Icon.tex", "TEX/ICON.tex"})
            main.write_bytes(reference("Tex/New.tex"))
            links.update(root, {main: 2, platform: 1}, {main})
            self.assertEqual(links.aliases["tex/icon.tex"], {"TEX/ICON.tex"})
            self.assertEqual(links.direct_parents("TEX/ICON.tex"), {"hud.uvs"})
            platform.unlink()
            links.update(root, {main: 2}, {platform})
            self.assertNotIn("tex/icon.tex", links.aliases)
            self.assertEqual(consumers(["tex/icon.tex"], first, links.index), {"tex/icon.tex", "hud.uvs"})
            main.unlink()
            links.update(root, {}, {main})
            self.assertEqual(links.graph["hud.uvs"], {"tex/stock.tex"})
            self.assertEqual(first.graph["hud.uvs"], {"tex/icon.tex"})

    def test_index_reuses_edges_and_publishes_only_after_reads_succeed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            owner, texture = root / "effect.efx.2818730", root / "texture.tex.28"
            raw = ("FX/Image.tex\0").encode("utf-16-le")
            links = ResourceLinks()
            links.update(root, {owner: 1}, {owner}, {owner: raw})
            first = links.index
            with patch.object(Path, "read_bytes", side_effect=AssertionError("unexpected read")):
                links.update(root, {owner: 2, texture: 1}, {owner, texture}, {owner: raw + b"\0\0"})
                links.update(root, {owner: 2, texture: 2}, {texture})
            self.assertIs(links.index, first)
            records = links.records
            missing = root / "missing.user.2"
            with self.assertRaises(FileNotFoundError):
                links.update(root, {owner: 3, missing: 1}, [owner, missing], {owner: b""})
            self.assertIs(links.index, first)
            self.assertIs(links.records, records)

    @unittest.skipUnless(os.name == "nt", "requires Windows directory notifications")
    def test_all_supported_suffixes_in_one_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "stm"
            root.mkdir()
            paths = [root / ("mod" + suffix) for suffix in SUFFIXES]
            stream = snapshots(root, files, signature, SUFFIXES)
            def until(predicate):
                deadline = time.monotonic() + 3
                while True:
                    snapshot = stream.send(.1)
                    if predicate(snapshot):
                        return snapshot
                    self.assertLess(time.monotonic(), deadline)
            try:
                self.assertFalse(next(stream))
                for file in paths:
                    file.write_bytes(b"mod A")
                before = until(lambda snapshot: len(snapshot) == len(paths))
                for file in paths:
                    stamp = file.stat()
                    with file.open("r+b") as writer:
                        writer.write(b"mod B")
                    os.utime(file, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                after = until(lambda snapshot: all(snapshot[file] != before[file] for file in paths))
                self.assertTrue(all(after[file][0] == before[file][0] for file in paths))
                for file in paths:
                    file.unlink()
                until(lambda snapshot: not snapshot)
            finally:
                stream.close()

    @unittest.skipUnless(os.name == "nt", "requires Windows directory notifications")
    def test_idle_and_unrelated_writes_do_not_walk_or_stat_mods(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "hunter.user.2").write_bytes(b"old")
            with patch("watch_outfit.files", wraps=files) as walk, patch("watch_outfit.signature", wraps=signature) as stat:
                stream = snapshots(root, walk, stat, SUFFIXES)
                try:
                    initial = next(stream)
                    (root / "editor.tmp").write_bytes(b"ignored")
                    for _ in range(3):
                        self.assertIs(stream.send(.05), initial)
                    self.assertEqual((walk.call_count, stat.call_count), (1, 1))
                finally:
                    stream.close()

    @unittest.skipUnless(os.name == "nt", "requires Windows directory notifications")
    def test_moving_a_directory_in_renaming_and_moving_out(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            root, outside = parent / "natives", parent / "pending"
            root.mkdir()
            outside.mkdir()
            (outside / "part.user.2").write_bytes(b"mod")
            stream = snapshots(root, files, signature, SUFFIXES)
            try:
                self.assertFalse(next(stream))
                def wait_for(expected):
                    deadline = time.monotonic() + 2
                    while set(stream.send(.1)) != expected:
                        self.assertLess(time.monotonic(), deadline, expected)
                dest = root / "outfit"
                outside.rename(dest)
                wait_for({dest / "part.user.2"})
                new = root / "other"
                dest.rename(new)
                wait_for({new / "part.user.2"})
                new.rename(outside)
                wait_for(set())
            finally:
                stream.close()

    @unittest.skipUnless(os.name == "nt", "requires Windows directory notifications")
    def test_lost_notifications_reconcile_preserved_signatures(self):
        with tempfile.TemporaryDirectory() as directory, patch("file_changes.LooseChanges") as factory:
            root = Path(directory)
            file = root / "part.user.2"
            file.write_bytes(b"mod")
            factory.return_value.poll.return_value = (set(), set(), True)
            stream = snapshots(root, files, signature, SUFFIXES)
            try:
                initial = next(stream)
                self.assertIs(stream.send(.1), initial)
                old = file.stat()
                time.sleep(.03)
                file.write_bytes(b"new")
                os.utime(file, ns=(old.st_atime_ns, old.st_mtime_ns))
                after = stream.send(.1)
                self.assertEqual(after[file][0], initial[file][0])
                self.assertNotEqual(after[file], initial[file])
                self.assertIs(stream.send(.1), after)
            finally:
                stream.close()

    @unittest.skipUnless(os.name == "nt", "requires NTFS file identity and hard links")
    def test_overflow_after_own_platform_publication_preserves_real_edits(self):
        with tempfile.TemporaryDirectory() as directory, patch("file_changes.LooseChanges") as factory:
            base = Path(directory)
            root = base / "natives/stm"
            root.mkdir(parents=True)
            paths = [root / (name + ".tex.28") for name in ("unchanged", "edited", "replaced", "renamed", "deleted")]
            unchanged, edited, replaced, renamed, deleted = paths
            for file in paths:
                file.write_bytes(b"mod")
            manager = PlatformFiles(root, base / "state")
            factory.return_value.poll.return_value = set(), set(), True
            stream = snapshots(root, files, signature, SUFFIXES, known_link_change=manager.known_link_change)
            try:
                initial = next(stream)
                time.sleep(.03)
                manager.prepare(paths)
                with manager.pin_copy(unchanged) as held:
                    self.assertEqual(held.read(), b"mod")
                self.assertIs(stream.send(.1), initial)
                time.sleep(.03)
                old = edited.stat()
                Path(str(edited) + ".stm").write_bytes(b"new")
                os.utime(edited, ns=(old.st_atime_ns, old.st_mtime_ns))
                replacement = root / "fresh.tmp"
                replacement.write_bytes(b"mod")
                os.replace(replacement, replaced)
                new_name = root / "moved.tex.28"
                renamed.rename(new_name)
                deleted.unlink()
                after = stream.send(.1)
                self.assertEqual(after[unchanged], initial[unchanged])
                self.assertEqual(after[edited][0], initial[edited][0])
                self.assertNotEqual(after[edited], initial[edited])
                self.assertNotEqual(after[replaced][0], initial[replaced][0])
                self.assertIn(new_name, after)
                self.assertNotIn(renamed, after)
                self.assertNotIn(deleted, after)
                self.assertIs(stream.send(.1), after)
            finally:
                stream.close()
                manager.close()

    def test_overflow_without_change_time_conservatively_republishes(self):
        with tempfile.TemporaryDirectory() as directory, patch("file_changes.LooseChanges") as factory:
            with patch("file_changes.FileChangeTimes.read", return_value=None):
                root = Path(directory)
                file = root / "part.user.2"
                file.write_bytes(b"mod")
                factory.return_value.poll.return_value = set(), set(), True
                stream = snapshots(root, files, signature, SUFFIXES)
                try:
                    initial = next(stream)
                    self.assertNotEqual(initial[file], stream.send(.1)[file])
                finally:
                    stream.close()

    @unittest.skipUnless(os.name == "nt", "requires Windows directory notifications")
    def test_replace_stm_or_natives_while_watching(self):
        with tempfile.TemporaryDirectory() as directory:
            game = Path(directory)
            root = game / "natives/stm"
            file = root / "part.user.2"
            stream = snapshots(root, files, signature, SUFFIXES, anchor=game)
            def wait_for(expected):
                end = time.monotonic() + 2
                while bool(stream.send(.1)) != expected:
                    self.assertLess(time.monotonic(), end, expected)
            try:
                self.assertFalse(next(stream))
                root.mkdir(parents=True)
                file.write_bytes(b"A")
                wait_for(True)
                for folder in (root, root.parent):
                    away = game / "away"
                    folder.rename(away)
                    wait_for(False)
                    away.rename(folder)
                    wait_for(True)
                file.unlink()
                wait_for(False)
            finally:
                stream.close()

    @unittest.skipUnless(os.name == "nt", "requires the Windows request watcher")
    def test_request_signal_filters_status_and_rearms_after_atomic_replace(self):
        dll_path = Path(__file__).resolve().parents[1] / "reframework/data/MHRS-Files-HotReload/mhrs_hotreload.dll"
        dll = ctypes.CDLL(str(dll_path))
        changed, close = dll.mhrs_request_changed, dll.mhrs_close_request_watch
        old_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            channel = Path(directory) / "reframework/data/MHRS-Files-HotReload"
            channel.mkdir(parents=True)
            os.chdir(directory)
            try:
                self.assertTrue(changed(None))
                self.assertFalse(changed(None))
                (channel / "status.json").write_text("ack")
                time.sleep(.02)
                self.assertFalse(changed(None))
                for generation in ("one", "two"):
                    tmp = channel / "new.tmp"
                    tmp.write_text(generation)
                    tmp.replace(channel / "request.json")
                    end = time.monotonic() + 1
                    while not changed(None):
                        self.assertLess(time.monotonic(), end, "missed request.json")
                        time.sleep(.005)
                close(None)
                self.assertTrue(changed(None))
                self.assertFalse(changed(None))
            finally:
                close(None)
                os.chdir(old_cwd)

    @unittest.skipUnless(os.name == "nt", "requires NTFS directory notifications")
    def test_in_place_overwrite_keeps_identity_size_and_time(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "appearance.user.2"
            path.write_bytes(b"mod A")
            stream = snapshots(root, files, signature, SUFFIXES)
            try:
                before = next(stream)
                stamp = path.stat()
                with path.open("r+b") as writer:
                    writer.write(b"mod B")
                    writer.flush()
                    with self.assertRaises(OSError):
                        require_closed_writers([path])
                os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                self.assertEqual(signature(path), before[path][0])
                require_closed_writers([path])
                end = time.monotonic() + 2
                while next(stream)[path] == before[path]:
                    self.assertLess(time.monotonic(), end)
                    time.sleep(.01)
                path.unlink()
                # The overlapped directory notification may complete after
                # unlink returns. next(stream) is a zero-time poll.
                end = time.monotonic() + 2
                while path in stream.send(.05):
                    self.assertLess(time.monotonic(), end, "missed file removal")
            finally:
                stream.close()

    def test_reference_replacement_uses_both_generations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "sequence.uvs.7.stm"
            parent = root / "owner.efx.2818730"
            def ref(path):
                return path.encode("utf-16-le") + b"\0\0"
            child.write_bytes(ref("VFX/TexA.tex"))
            parent.write_bytes(ref("VFX/nested.uvs"))
            graph = ResourceLinks()
            graph.update(root, {child: 1, parent: 1})
            old = graph.graph
            self.assertEqual(graph.aliases["vfx/texa.tex"], {"VFX/TexA.tex"})
            child.write_bytes(ref("VFX/TexB.tex"))
            graph.update(root, {child: 2, parent: 1})
            for name in ("texa", "texb"):
                self.assertIn("sequence.uvs", consumers(["vfx/" + name + ".tex"], old, graph.graph))
            self.assertEqual(logical_path(root, child), "sequence.uvs")

    def test_transitive_and_cyclic_parents(self):
        old = {"a.pfb": {"b.user"}, "b.user": {"a.pfb", "c.motbank"}}
        new = {"c.motbank": {"d.motlist"}, "d.motlist": {"e.mot"}}
        self.assertEqual(consumers(["E.MOT"], old, new),
                         {"a.pfb", "b.user", "c.motbank", "d.motlist", "e.mot"})

    def test_hud_sequence_keeps_running_view_and_prefab(self):
        graph = {"hud.gui": {"icons.uvs"}, "hud.pfb": {"hud.gui"}, "sparks.efx": {"icons.uvs"}}
        changed = consumers(["icons.uvs"], graph)
        self.assertEqual(changed, {"icons.uvs", "sparks.efx"})
        changed = consumers(["icons.uvs", "hud.gui"], graph)
        self.assertEqual(changed, {"icons.uvs", "sparks.efx", "hud.gui", "hud.pfb"})

    def test_item_preview_finds_embedding_menus_and_honors_loose_overrides(self):
        links = ResourceLinks()
        sequence = "camera/texture/rendertarget/previewtexture_equipmini.uvs"
        embedded = "gui/00_symbolorigin/preview_obj.gui"
        box = "gui/01_common/facility/equipchange.gui"
        forge = "gui/01_common/facility/smithy.gui"
        self.assertTrue({embedded, box, forge} <= set(links.gui_owners(sequence)))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            override = root / (box + ".430033")
            override.parent.mkdir(parents=True)
            override.write_bytes("gui/other.gui".encode("utf-16-le"))
            links.update(root, {override: 1})
            self.assertNotIn(box, links.gui_owners(sequence))
            self.assertIn(forge, links.gui_owners(sequence))

    def test_prefab_changes_preserve_userdata_containing_factory(self):
        graph = {"owner.user": {"item.pfb"}, "outer.pfb": {"owner.user"}}
        self.assertEqual(consumers(["item.pfb"], graph), {"item.pfb"})
        self.assertEqual(consumers(["owner.user", "item.pfb"], graph), {"item.pfb", "owner.user", "outer.pfb"})

    def test_packaged_factory_and_loose_override(self):
        links = ResourceLinks()
        mesh = "player/mod/f/pl279/f_arm279.mesh"
        prefab = "player/prefab/mod/f/pl279/f_arm279.pfb"
        self.assertIn(prefab, consumers([mesh], packaged=links.stock_parents))
        override = {prefab: {"player/mod/f/pl265/f_arm265.mesh"}}
        self.assertNotIn(prefab, consumers([mesh], override, packaged=links.stock_parents, overrides=override))
        self.assertIn("gui/80_texture/photo/photo_02.rtex", links.stock_aliases)

    def test_shared_template_packaged_interface(self):
        with tempfile.TemporaryDirectory() as directory:
            validator = MaterialValidator(Path(directory))
            path = "mastermaterial/master/obj/npc/pl_npc_mmtrv/pl_default.mmtr"
            layout = validator.packaged_shaders[path]
            material = Material("Body", path, 160, set(layout[1]), set(layout[2]), {}, {})
            check_layout(material, layout)
            material.size = 144
            with self.assertRaises(IncompatibleMaterial):
                check_layout(material, layout)


if __name__ == "__main__":
    unittest.main()
