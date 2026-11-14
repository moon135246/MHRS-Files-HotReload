"""Index loose Rise resource references and map versioned filenames to logical paths."""
import re


def logical_path(root, file):
    relative = file.relative_to(root).as_posix()
    if relative.lower().endswith(".stm"):
        relative = relative[:-4]
    return relative.rsplit(".", 1)[0]


def resource_paths(raw):
    # RE stores resource strings in UTF-16LE in effects, UV sequences and motion lists.
    found = set()
    for match in re.finditer(rb"(?:[a-zA-Z0-9_/@.\\-]\x00){5,}", raw):
        path = match[0].decode("utf-16-le").lower().replace("\\", "/")
        if "/" in path and "." in path.rsplit("/", 1)[-1]:
            found.add(path.lstrip("@"))
    return found


class ResourceLinks:
    def __init__(self):
        self.records = {}

    def references(self, root, present):
        self.records = {f: row for f, row in self.records.items() if f in present}
        references = {}
        for f in sorted(present):
            owner = logical_path(root, f).lower()
            if not owner.endswith((".efx", ".motlist", ".uvs")):
                continue
            stat = f.stat()
            sig = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
            if f not in self.records or self.records[f][0] != sig:
                self.records[f] = sig, resource_paths(f.read_bytes())
            references.setdefault(owner, set()).update(self.records[f][1])
        return references

    def owners(self, root, present, path):
        refs = self.references(root, present)
        target = path.lower()
        direct = {owner for owner, paths in refs.items() if target in paths}
        intermediate = {}
        if target.endswith(".tex"):
            for uv in sorted(p for p in direct if p.endswith(".uvs")):
                parents = sorted(p for p, paths in refs.items() if p.endswith(".efx") and uv in paths)
                if parents:
                    intermediate[uv] = parents
        return sorted(p for p in direct if p.endswith((".efx", ".motlist"))), intermediate
