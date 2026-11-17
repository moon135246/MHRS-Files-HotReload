"""Menu time copies must coalesce, survive inactivity and never replay on different gear."""
from contextlib import ExitStack, redirect_stdout
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import watch_outfit
from watch_arm279 import signature


class Stop(Exception):
    pass


class WaitingWornTest(unittest.TestCase):
    def test_only_missing_named_mmtr_dependencies_are_parked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            validator = watch_outfit.MaterialValidator(root)
            validator.packaged_shaders = {"stock.mmtr": ()}
            (root / "loose.mmtr.220427553").touch()
            (root / "platform.mmtr.220427553.stm").touch()
            def read(path):
                if path.name == "unreadable.mmtr.220427553":
                    raise OSError("cannot read archive")
                if path.name == "packed.mmtr.220427553":
                    return b"shader"
            names = ("absent.mmtr", "stock.mmtr", "loose.mmtr", "platform.mmtr", "packed.mmtr",
                     "unreadable.mmtr", "absent.tex", "../outside.mmtr")
            rows = "\n".join("armor.mdf2\t0001\t" + name for name in names)
            result = watch_outfit.missing_material_dependencies(root, rows, Mock(read=read), validator)
            self.assertEqual(result, {(root / "armor.mdf2.23", root / "absent.mmtr.220427553"),
                                      (root / "armor.mdf2.23", root / "absent.tex.28")})

    def test_simultaneously_saved_components_retry_separately(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as st:
            game = Path(tmp)
            root = game / "natives/stm"
            root.mkdir(parents=True)
            (game / "reframework/data/MHRS-Files-HotReload").mkdir(parents=True)
            files = [root / "a.fbxskel.4", root / "b.rcol.20"]
            clock, attempts, committed = [0.], [], []
            current_job = [None]

            def snapshots(*args, **kwargs):
                wait = yield {}
                for file in files:
                    file.write_bytes(b"test component")
                snap = {f: (signature(f), 1) for f in files}
                for _ in range(15):
                    clock[0] += wait + .02
                    wait = yield snap
                raise Stop

            def command(channel, action, **opts):
                if action == "asset_begin":
                    current_job[0] = opts["path"]
                    attempts.append(opts["path"])
                    return {"address": "123"}
                if action == "asset_poll":
                    return {"state": "ready"}
                if action == "asset_bind":
                    if current_job[0] == "a.fbxskel" and attempts.count("a.fbxskel") == 1:
                        raise RuntimeError("Equipped binding changed")
                    committed.append(current_job[0])
                    return {"state": "committed", "resource": "456", "bindings": 1}
                if action == "asset_removed":
                    return {"results": [{"path": p, "state": "retired"} for p in opts["paths"]]}
                return {}

            st.enter_context(patch.object(watch_outfit, "snapshots", snapshots))
            st.enter_context(patch.object(watch_outfit, "command", command))
            st.enter_context(patch.object(watch_outfit.time, "monotonic", lambda: clock[0]))
            messages = st.enter_context(redirect_stdout(io.StringIO()))
            with self.assertRaises(Stop):
                watch_outfit.watch(game)
            self.assertEqual(committed, ["b.rcol", "a.fbxskel"], messages.getvalue())
            self.assertCountEqual(attempts, ["a.fbxskel", "a.fbxskel", "b.rcol"])

    def test_missing_template_waits_for_a_related_save(self):
        for wake in ("ordinary", "platform", "uninstall"):
            with self.subTest(wake=wake), tempfile.TemporaryDirectory() as tmp, ExitStack() as st:
                game = Path(tmp)
                root = game / "natives/stm"
                folder = root / "player/mod/f/pl888"
                folder.mkdir(parents=True)
                channel = game / "reframework/data/MHRS-Files-HotReload"
                channel.mkdir(parents=True)
                part = folder / "f_arm888.mesh.2109148288"
                other = folder / "f_leg888.mesh.2109148288"
                shader = root / "custom/测试.mmtr.220427553"
                shader.parent.mkdir()
                part_key = watch_outfit.logical_path(root, part)
                other_key = watch_outfit.logical_path(root, other)
                pending = "player/mod/f/pl888/f_arm888.mdf2\t0001\tcustom/测试.mmtr\n"
                clock, attempts, aborts = [0.], [], []

                def snapshots(*args, **kwargs):
                    current = {}
                    wait = yield current
                    for file, data in ((part, b"outfit"), (other, b"independent"),
                                       (part, None) if wake == "uninstall" else
                                       (shader if wake == "ordinary" else Path(str(shader) + ".stm"), b"template")):
                        current = current.copy()
                        if data is None:
                            file.unlink()
                            del current[file]
                        else:
                            file.write_bytes(data)
                            current[file] = (signature(file), 1)
                        for _ in range(25):
                            clock[0] += wait + .02
                            wait = yield current
                    raise Stop

                def command(channel, action, **opts):
                    if action == "asset_removed":
                        paths = set(opts["live_reentry"])
                        attempts.append(paths)
                        return dict(results=[dict(path=p, state="retired") for p in opts["paths"]],
                                    equipment=True, equipment_bindings=True)
                    if action == "asset_factories_ready":
                        if len(attempts) == 1:
                            (channel / "equipment-wait.txt").write_text(pending, encoding="utf-8")
                            clock[0] += 13
                            return dict(pending=True, equipment_pending=True)
                        return dict(pending=False)
                    if action == "asset_equipment_abort":
                        aborts.append(True)
                    return {}

                st.enter_context(patch.object(watch_outfit, "snapshots", snapshots))
                st.enter_context(patch.object(watch_outfit, "command", command))
                st.enter_context(patch.object(watch_outfit.MaterialValidator, "layout", return_value=None))
                st.enter_context(patch.object(watch_outfit.time, "monotonic", lambda: clock[0]))
                messages = st.enter_context(redirect_stdout(io.StringIO()))
                with self.assertRaises(Stop):
                    watch_outfit.watch(game)
                last = {part_key, "custom/测试.mmtr"} if wake != "uninstall" else {part_key}
                self.assertEqual(attempts, [{part_key}, {other_key}, last], messages.getvalue())
                self.assertEqual(aborts, [True])
                self.assertEqual(messages.getvalue().count("Missing MMTR: natives/stm/custom/测试.mmtr.220427553"), 1)

    def simulate(self, observed, uninstall=False):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as st:
            game = Path(tmp)
            folder = game / "natives/stm/player/mod/f/pl888"
            folder.mkdir(parents=True)
            (game / "reframework/data/MHRS-Files-HotReload").mkdir(parents=True)
            mesh = folder / "f_arm888.mesh.2109148288"
            key = "player/mod/f/pl888/f_arm888.mesh"
            clock, ready = [0.], [False]
            applied, polls = [], []
            def snapshots(*args, **kwargs):
                wait = yield {}
                for number, data in enumerate((b"first", None if uninstall else b"second"), 1):
                    clock[0] += wait + .02
                    if data is None:
                        mesh.unlink()
                    else:
                        mesh.write_bytes(data)
                    snap = {mesh:(signature(mesh), number)} if data else {}
                    for _ in range(5):
                        wait = yield snap
                        clock[0] += wait + .02
                ready[0] = True
                for _ in range(6):
                    wait = yield snap
                    clock[0] += wait + .02
                raise Stop

            def command(channel, action, **opts):
                if action == "asset_worn_state":
                    polls.append((ready[0], opts["paths"]))
                    return {"ready":ready[0], "observed":{key:observed} if observed else {},
                            "available":{key:True} if observed else {}}
                if action == "asset_removed":
                    self.assertEqual(opts["live_reentry"], [key])
                    applied.append((opts.get("worn_retry"), mesh.read_bytes() if mesh.exists() else None))
                    return {"results":[{"path":p,"state":"retired"} for p in opts["paths"]],
                            "waiting_equipment":{} if ready[0] else {key:"old"}}
                return {}

            st.enter_context(patch.object(watch_outfit, "snapshots", snapshots))
            st.enter_context(patch.object(watch_outfit, "command", command))
            st.enter_context(patch.object(watch_outfit.time, "monotonic", lambda: clock[0]))
            messages = st.enter_context(redirect_stdout(io.StringIO()))
            with self.assertRaises(Stop):
                watch_outfit.watch(game)
            self.assertTrue(any(not was_ready for was_ready, _ in polls), messages.getvalue())
            self.assertEqual(sum(was_ready for was_ready, _ in polls), 1, messages.getvalue())
            return applied,key

    def test_compound_vertex_proof_keeps_peers_and_single_local_mesh_only(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as st:
            game = Path(tmp)
            root = game / "natives/stm"
            folder = root / "player/mod/f/pl888"
            folder.mkdir(parents=True)
            (game / "reframework/data/MHRS-Files-HotReload").mkdir(parents=True)
            parts = [folder / f"f_{slot}888.mesh.2109148288" for slot in ("arm", "body", "helm", "leg", "wst")]
            keys = {file: watch_outfit.logical_path(root, file) for file in parts}
            leg = parts[3]
            peer = keys[parts[0]]
            clock = [0.]
            proofs = []

            def snapshots(*args, **kwargs):
                wait = yield {}
                for file in parts:
                    file.write_bytes(b"fixture mesh")
                current = {file: (signature(file), 1) for file in parts}
                for removed in ((), (leg,), tuple(file for file in parts if file != leg)):
                    for file in removed:
                        file.unlink()
                    current = {file: entry for file, entry in current.items() if file not in removed}
                    for _ in range(4):
                        clock[0] += wait + .02
                        wait = yield current
                raise Stop

            def command(channel, action, **opts):
                if action == "asset_peer_meshes":
                    return {"master": dict.fromkeys(keys.values(), True), "paths": {peer: True}}
                if action == "asset_removed":
                    proofs.append((set(opts["live_reentry"]), set(opts["peer_meshes"]), set(opts["stock_meshes"])))
                    return {"results": [{"path": p, "state": "retired"} for p in opts["paths"]]}
                return {}

            st.enter_context(patch.object(watch_outfit, "snapshots", snapshots))
            st.enter_context(patch.object(watch_outfit, "command", command))
            st.enter_context(patch.object(watch_outfit, "vertex_edit", return_value=True))
            st.enter_context(patch.object(watch_outfit.RisePak, "read", return_value=b"stock mesh"))
            st.enter_context(patch.object(watch_outfit.time, "monotonic", lambda: clock[0]))
            st.enter_context(redirect_stdout(io.StringIO()))
            with self.assertRaises(Stop):
                watch_outfit.watch(game)
            remaining = set(keys.values()) - {keys[leg]}
            self.assertEqual(proofs, [(set(keys.values()), {peer}, set()), ({keys[leg]}, {keys[leg]}, {keys[leg]}),
                                      (remaining, {peer}, remaining)])

    def test_menu_copies_apply_once_using_final_disk_generation(self):
        for uninstall in (False, True):
            with self.subTest(uninstall=uninstall):
                applied,key = self.simulate("old", uninstall)
                last = None if uninstall else b"second"
                self.assertEqual(applied, [(None,b"first"), (None,last), ({key:"old"},last)])

    def test_changed_gear_and_natural_reload_cancel_pending_model_request(self):
        for observed in (None, "fresh"):
            with self.subTest(observed=observed):
                applied,_ = self.simulate(observed)
                self.assertEqual(applied, [(None,b"first"), (None,b"second")])

    def test_complete_outfit_retries_current_generation_on_the_original_root(self):
        for scenario in ("success", "partial fallback", "new copy", "natural equip", "different gear",
                         "same map new instance", "between hunters", "new generation"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as tmp, ExitStack() as st:
                game = Path(tmp)
                root = game / "natives/stm"
                folder = root / "player/mod/f/pl888"
                folder.mkdir(parents=True)
                (game / "reframework/data/MHRS-Files-HotReload").mkdir(parents=True)
                parts = [folder / f"f_{slot}888.mesh.2109148288" for slot in ("body", "arm", "helm", "leg", "wst")]
                worn = {watch_outfit.logical_path(root, path): str(i + 20) for i, path in enumerate(parts)}
                if scenario == "partial fallback":
                    parts = parts[:1]  # only this worn file changed; guard still records the entire wearer
                targets = {watch_outfit.logical_path(root, path): worn[watch_outfit.logical_path(root, path)] for path in parts}
                root_id, scope = "hunter1", "quest/101/1/4455"
                next_scope = "quest/101/1/7788"
                moving = scenario in ("same map new instance", "between hunters", "different gear")
                rediscovered = {p: str(i+90) for i,p in enumerate(worn)}
                clock, ready, applications = [0.], [False], []
                polls = []

                def snapshots(*args, **kwargs):
                    yield {}
                    for f in parts:
                        f.write_bytes(b"install")
                    current = {f: (signature(f), 1) for f in parts}
                    for n in range(45):
                        if n == 7 and scenario == "new copy":
                            parts[0].write_bytes(b"final copy")
                            current = {**current, parts[0]: (signature(parts[0]), 4)}
                        if n == 16:
                            ready[0] = True
                        clock[0] += .7
                        yield current
                    raise Stop

                def command(channel, action, **opts):
                    if action == "asset_worn_state":
                        polls.append((ready[0], opts.get("wait_factory")))
                        self.assertNotIn("wait_rebuild", opts)
                        observed = dict(worn)
                        if ready[0] and scenario == "new generation":
                            observed[next(iter(worn))] = "other"
                        if moving and ready[0]:
                            observed = {} if scenario == "different gear" else rediscovered
                        return dict(root="other" if moving and ready[0] else root_id,
                                    scope=next_scope if moving and ready[0] else scope, ready=ready[0],
                                    complete_outfit=len(observed)==5, observed=observed, available=dict.fromkeys(worn, True))
                    if action == "asset_removed":
                        self.assertEqual(set(opts["live_reentry"]), set(targets))
                        applications.append((opts.get("worn_guard"), opts.get("worn_retry"), parts[0].read_bytes()))
                        return {"results": [{"path": p, "state": "retired"} for p in opts["paths"]], "equipment": True}
                    if action == "asset_factories_ready":
                        if applications[-1][0] is None:
                            if scenario == "between hunters":
                                return dict(pending=False, worn_mount=dict(discover=True, worn=dict.fromkeys(worn, True),
                                            retry=True, reason="Waiting for current scene armor consumers"))
                            return dict(pending=False, worn_mount=dict(root=root_id, scope=scope, worn=worn, wait_factory=scenario != "partial fallback", partial=scenario == "partial fallback",
                                        reason="Shared cold armor factory", retry=scenario != "natural equip"))
                        return dict(pending=False)
                    return {}

                st.enter_context(patch.object(watch_outfit, "snapshots", snapshots))
                st.enter_context(patch.object(watch_outfit, "command", command))
                st.enter_context(patch.object(watch_outfit.time, "monotonic", lambda: clock[0]))
                st.enter_context(redirect_stdout(io.StringIO()))
                with self.assertRaises(Stop):
                    watch_outfit.watch(game)
                ordinary = [a for a in applications if a[0] is None]
                queued = [a for a in applications if a[0] is not None]
                self.assertEqual([a[2] for a in ordinary], [b"install"] + ([b"final copy"] if scenario == "new copy" else []))
                if scenario in ("success", "partial fallback", "new copy"):
                    self.assertEqual(queued, [({"root": root_id, "scope": scope}, targets, ordinary[-1][2])])
                elif scenario in ("same map new instance", "between hunters"):
                    self.assertEqual(queued, [({"root": "other", "scope": next_scope}, rediscovered, b"install")])
                else:
                    self.assertEqual(queued, [])
                self.assertEqual(bool(polls), scenario != "natural equip")
                self.assertTrue(all(bool(factory) == (scenario not in ("partial fallback", "between hunters")) for _, factory in polls))


if __name__ == "__main__":
    unittest.main()
