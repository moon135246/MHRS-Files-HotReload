"""A rejected worn CHAIN is retried together with the Mesh supplied by the next copy."""
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


class RejectedChainTest(unittest.TestCase):
    def run_install(self, reject_at, reason, progress=None, sleeps=None):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as st:
            game = Path(tmp)
            folder = game / "natives/stm/player/mod/f/pl888"
            folder.mkdir(parents=True)
            (game / "reframework/data/MHRS-Files-HotReload").mkdir(parents=True)
            chain = folder / "f_arm888.chain.48"
            mesh = folder / "f_arm888.mesh.2109148288"
            clock = [1.]
            batches = []
            last = []
            def snapshots(*args, **kwargs):
                wait = yield {}
                clock[0] += wait + 0.01
                chain.write_bytes(b"\x30\0\0\0chan" + bytes(104))
                one = {chain: (signature(chain), 1)}
                for _ in range(9):
                    wait = yield one
                    clock[0] += wait + 0.01
                mesh.write_bytes(b"new mesh for synthetic 888")
                two = {**one, mesh: (signature(mesh), 2)}
                for _ in range(5):
                    wait = yield two
                    clock[0] += wait + 0.01
                raise Finished

            def command(channel, action, **payload):
                nonlocal last
                if action == "asset_removed":
                    last = sorted(p.rsplit(".", 1)[-1] for p in payload["live_reentry"])
                    batches.append(last)
                    if last == ["chain"] and reject_at == action:
                        raise RuntimeError(reason)
                    return {"results":[{"path":p,"state":"retired"} for p in payload["paths"]],"equipment": True}
                if action == "asset_factories_ready":
                    if last == ["chain"] and reject_at == action:
                        raise RuntimeError(reason)
                    if progress:
                        return progress.pop(0)
                    return {"pending":False}
                return {}

            st.enter_context(patch.object(watch_outfit, "snapshots", snapshots))
            st.enter_context(patch.object(watch_outfit, "command", command))
            st.enter_context(patch.object(watch_outfit.time, "monotonic", side_effect=lambda: clock[0]))
            if sleeps is not None:
                st.enter_context(patch.object(watch_outfit.time, "sleep", side_effect=sleeps.append))
            messages = st.enter_context(redirect_stdout(io.StringIO()))
            with self.assertRaises(Finished):
                watch_outfit.watch(game)
            return batches,messages.getvalue()

    def test_only_local_frame_handoffs_omit_the_background_poll_delay(self):
        sleeps = []
        progress = [{"pending": True, "next_update": value} for value in (True, False, True, 1)]
        progress += [{"pending": True}, {"pending": False, "next_update": True}]
        self.run_install(None, "", progress, sleeps)
        self.assertFalse(progress)
        self.assertEqual(sleeps, [.05, .05, .05])

    def test_missing_terminal_is_rejected_once_then_new_mesh_retries_both(self):
        for when in ("asset_removed", "asset_factories_ready"):
            with self.subTest(when=when):
                batches, log = self.run_install(when, "Lua: Incompatible CHAIN terminal Hair07 for player/mod/f/pl888/f_arm888.chain")
                self.assertEqual(batches, [["chain"], ["chain", "mesh"]], log)
                self.assertEqual(log.count("Rejected copy"), 1, log)
                self.assertNotIn("Reload pending", log)

    def test_loading_resource_retries_without_another_copy(self):
        batches, log = self.run_install("asset_factories_ready","ResourceManager still preparing")
        self.assertGreater(batches.count(["chain"]), 1, log)
        self.assertEqual(batches[-1], ["chain","mesh"], log)
        self.assertNotIn("Rejected copy", log)


if __name__ == "__main__":
    unittest.main()
