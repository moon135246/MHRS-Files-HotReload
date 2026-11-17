"""Index path references in extracted Rise assets. The output contains only names."""
import argparse
import gzip
import json
import mmap
from pathlib import Path
import re

from resource_links import INDEX, REFERENCE_SUFFIXES, logical_path
from material_layout import SHADER_INDEX, shader_layout


def build(root, filelist, destination):
    extensions = ("chain", "jcns", "motbank", "motlist", "mot", "uvar", "fbxskel", "efx",
                  "rcol", "gui", "pfb", "user", "mesh", "mdf2", "tex", "rtex", "mmtr", "uvs")
    relative = re.compile(r"^natives/stm/(.+\.(?:" + "|".join(extensions) + r"))\.\d+(?:\.stm)?$", re.I)
    known = {m[1].lower() for line in filelist.read_text(encoding="utf-8-sig").splitlines()
             if (m := relative.fullmatch(line.strip()))}
    ending = re.compile(b"\\.\x00(?:" + b"|".join(s.encode("utf-16-le") for s in extensions) + b")\x00\x00", re.I)
    chars = set(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/@.\\-")
    owners, shaders = {}, {}
    for file in root.rglob("*"):
        if file.name.lower().endswith(".mmtr.220427553") and file.stat().st_size:
            try:
                shaders[logical_path(root, file).lower()] = [sorted(t) for t in shader_layout(file.read_bytes())]
            except ValueError as error:
                print(file.name, error)
            continue
        if not file.name.lower().endswith(REFERENCE_SUFFIXES) or not file.stat().st_size:
            continue
        references = set()
        with file.open("rb") as src, mmap.mmap(src.fileno(), 0, access=mmap.ACCESS_READ) as data:
            for match in ending.finditer(data):
                start = match.start()
                while start >= 2 and data[start-1] == 0 and data[start-2] in chars:
                    start -= 2
                name = data[start:match.end()-2].decode("utf-16-le").replace("\\", "/").lstrip("@")
                if name.lower() in known:
                    references.add(name)
        if references:
            owner = logical_path(root, file)
            owners.setdefault(owner, set()).update(references)
    print(len(owners), "resources,", sum(map(len, owners.values())), "references")
    indexed = {name.lower() for name in owners}
    indexed.update(child.lower() for children in owners.values() for child in children)
    owners.update((name, ()) for name in known - indexed)
    data = json.dumps({k: sorted(v) for k, v in sorted(owners.items())}, separators=(",", ":")).encode()
    destination.write_bytes(gzip.compress(data, compresslevel=9, mtime=0))
    layouts = json.dumps(shaders, sort_keys=True, separators=(",", ":")).encode()
    destination.with_name(SHADER_INDEX.name).write_bytes(gzip.compress(layouts, compresslevel=9, mtime=0))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stock_stm", type=Path)
    parser.add_argument("filelist", type=Path)
    parser.add_argument("--output", type=Path, default=INDEX)
    args = parser.parse_args()
    build(args.stock_stm, args.filelist, args.output)
