from pathlib import Path
from contextlib import redirect_stdout, redirect_stderr
import os
import traceback


def run():
    game = Path.cwd()
    channel = game / "reframework/data/MHRS-Files-HotReload"
    with ((channel / "watcher.log").open("w", encoding="utf-8", buffering=1) as output,
          redirect_stdout(output), redirect_stderr(output)):
        try:
            from watch_outfit import watch
            print("In-process watcher PID", os.getpid())
            watch(game)
        except KeyboardInterrupt:
            print("Watcher stopped")
        except Exception:
            traceback.print_exc()
            raise
