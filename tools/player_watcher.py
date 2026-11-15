"""Standalone watcher launched with the Rise installation as its working directory."""
import sys
import traceback
from pathlib import Path

from watch_outfit import watch


if __name__ == "__main__":
    game = Path.cwd()
    log = game / "reframework/data/MHRS-Files-HotReload/watcher.log"
    with log.open("w", encoding="utf-8", buffering=1) as output:
        sys.stdout = sys.stderr = output
        try:
            watch(game)
        except Exception:
            traceback.print_exc()
            sys.exit(1)
