"""Read the same resource indexes and honor cancellation in either watcher host."""
import gzip
import io
import sys
from pathlib import Path


if "_mhrs_runtime" in sys.builtin_module_names:
    from _mhrs_runtime import checkpoint, index

    def index_path(name):
        return Path(name)

    def open_index(path):
        return gzip.open(io.BytesIO(index(path.name)), "rt", encoding="utf-8")
else:
    def checkpoint():
        pass

    def index_path(name):
        return Path(__file__).with_name(name)

    def open_index(path):
        return gzip.open(path, "rt", encoding="utf-8")
