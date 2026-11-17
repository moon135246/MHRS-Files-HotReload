from contextlib import ExitStack, redirect_stdout
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import watch_outfit
from watch_arm279 import signature


class Finished(Exception):
    pass


class MountResetTests(unittest.TestCase):
    def test_worker_validates_current_copy_only_after_local_recovery(self):
        with tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
            game = Path(folder)
            root = game / "natives/stm"
            channel = game / "reframework/data/MHRS-Files-HotReload"
            channel.mkdir(parents=True)
            (channel / "part-recovery.json").write_text("{}")
            plugins = game / "reframework/plugins"
            plugins.mkdir()
            (plugins / "FirstNatives.dll").touch()
            (game / "re2_fw_config.txt").write_text("LooseFileLoader_Enabled=false")
            arm = "player/mod/f/pl279/f_arm279.mesh"
            bone = "player/mod/f/bone/f_shadow.mesh"
            f = root / (arm + ".2109148288")
            f.parent.mkdir(parents=True)
            f.write_bytes(b"latest gear")
            current = {f: (signature(f), 1)}
            polls, batches, clock = [], [], [0.]

            def snapshots(*args, **kwargs):
                wait = yield current
                for _ in range(5):
                    clock[0] += wait + .25
                    wait = yield current
                raise Finished

            def command(_, action, **payload):
                if action == "asset_part_recovery":
                    polls.append(1)
                    if len(polls) == 1:
                        return {"pending": True}
                    return {"id": "root/recovery", "worn": {arm: "current-holder"},
                            "paths": {arm: True, bone: True}, "suit": "player/mod/f/pl279/f_shadow.mesh"}
                if action == "asset_removed":
                    batches.append((payload, f.read_bytes()))
                    return {"results": [{"path": p, "state": "retired"} for p in payload["paths"]], "equipment": 2}
                if action == "asset_factories_ready":
                    return {"pending": False}
                return {}

            stack.enter_context(patch.object(watch_outfit, "snapshots", snapshots))
            stack.enter_context(patch.object(watch_outfit, "command", command))
            stack.enter_context(patch.object(watch_outfit.time, "monotonic", lambda: clock[0]))
            shadows = stack.enter_context(patch.object(watch_outfit, "shadow_targets", return_value={"f": {}}))
            out = stack.enter_context(redirect_stdout(io.StringIO()))
            with self.assertRaises(Finished):
                watch_outfit.watch(game)
            self.assertEqual(len(polls), 2, out.getvalue())
            self.assertEqual(len(batches), 1, out.getvalue())
            payload, current_bytes = batches[0]
            self.assertEqual(current_bytes, b"latest gear")
            self.assertEqual(payload["reset_replay"], "root/recovery")
            self.assertEqual(payload["worn_retry"], {arm: "current-holder"})
            self.assertEqual(set(payload["live_reentry"]), {arm, bone})
            self.assertIs(shadows.call_args.args[2], current)

    def test_outside_path_rejected(self):
        with self.assertRaises(ValueError):
            watch_outfit.recovery_files(Path("."), {"paths": {"../f_shadow.mesh": True}}, {})
