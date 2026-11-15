"""Index loose Rise resource references and map versioned filenames to logical paths."""
import gzip
import json
import re
from collections import defaultdict
from pathlib import Path


# Stock UV sequences used by Rise's preview windows. Each sequence contains
# a normal and an ultrawide target. A loose UVS supplies its own references.
PREVIEW_UVS = {
    "previewcamera": "previewtexture_pl",
    "previewcamera_plbig": "previewtexture_plbig",
    "previewcamera_otomo": "previewtexture_otomo",
    "previewcamera_equip": "previewtexture_equip",
    "previewcamera_objmini": "previewtexture_equipmini",
}


def logical_path(root, file):
    relative = file.relative_to(root).as_posix()
    if relative.lower().endswith(".stm"):
        relative = relative[:-4]
    return relative.rsplit(".", 1)[0]


def resource_paths(raw, *, preserve_case=False):
    # RE stores resource strings in UTF-16LE in effects, UV sequences and motion lists.
    found = set()
    for match in re.finditer(rb"(?:[a-zA-Z0-9_/@.\\-]\x00){5,}", raw):
        path = match[0].decode("utf-16-le").replace("\\", "/")
        if "/" in path and "." in path.rsplit("/", 1)[-1]:
            found.add(path.lstrip("@") if preserve_case else path.lstrip("@").lower())
    return found


REFERENCE_SUFFIXES = (".pfb.17", ".user.2", ".gui.430033", ".mdf2.23", ".efx.2818730",
                      ".motlist.528", ".motbank.3", ".uvs.7", ".uvs.7.stm")
INDEX = Path(__file__).with_name("rise-16.0.2-links.json.gz")

_PREVIEW_DIR = "camera/texture/rendertarget/"
_PREVIEW_LINKS = {_PREVIEW_DIR + uv + ".uvs": {_PREVIEW_DIR + camera + ".rtex", _PREVIEW_DIR + camera + "_uw.rtex"}
                  for camera, uv in PREVIEW_UVS.items()}


class ReferenceIndex:
    """One published generation. A changed owner replaces only its own reverse edges."""

    def __init__(self, previous=None):
        if previous is None:
            self.sources = {}
            self.graph = _PREVIEW_LINKS.copy()
            self.parents = {}
            self.aliases = {}
            for owner, children in self.graph.items():
                for child in children:
                    self.parents.setdefault(child, {})[owner] = frozenset()
        else:
            self.sources = previous.sources.copy()
            self.graph = previous.graph.copy()
            self.parents = previous.parents.copy()
            self.aliases = previous.aliases.copy()

    def updated(self, edits):
        if not edits:
            return self
        grouped = defaultdict(dict)
        for relative, refs in edits.items():
            grouped[logical_path(Path("."), relative).lower()][relative] = refs
        result = ReferenceIndex(self)
        changed_children = set()
        for owner, changes in grouped.items():
            variants = self.sources.get(owner, {}).copy()
            for relative, refs in changes.items():
                if refs is None:
                    variants.pop(relative, None)
                else:
                    variants[relative] = refs
            children = {}
            if variants:
                result.sources[owner] = variants
                for refs in variants.values():
                    for name in refs:
                        children.setdefault(name.lower(), set()).add(name)
            else:
                result.sources.pop(owner, None)
                children = {p: frozenset() for p in _PREVIEW_LINKS.get(owner, ())}
            if variants or children:
                result.graph[owner] = set(children)
            else:
                result.graph.pop(owner, None)
            for child in self.graph.get(owner, set()) | children.keys():
                old = self.parents.get(child, {})
                forms = children.get(child)
                if old.get(owner) == forms:
                    continue
                if child not in changed_children:
                    result.parents[child] = old.copy()
                    changed_children.add(child)
                if forms is None:
                    result.parents[child].pop(owner)
                else:
                    result.parents[child][owner] = forms
        # Recover exact spellings from all remaining contributors, including a
        # sibling platform file or another owner still using a mixed-case path.
        for key in changed_children | grouped.keys():
            names = {logical_path(Path("."), rel) for rel in result.sources.get(key, ())}
            for forms in result.parents.get(key, {}).values():
                names.update(forms)
            if names:
                result.aliases[key] = names
            else:
                result.aliases.pop(key, None)
            if not result.parents.get(key):
                result.parents.pop(key, None)
        return result


def consumers(paths, *graphs, packaged=None, overrides=()):
    """Find resources to reopen across changes, shared consumers and reference cycles."""
    indexes = []
    for graph in graphs:
        if isinstance(graph, ReferenceIndex):
            indexes.append(graph.parents)
        else:
            reverse = defaultdict(set)
            for owner, children in graph.items():
                for child in children:
                    reverse[child].add(owner)
            indexes.append(reverse)
    shadowed = overrides if callable(overrides) else lambda owner: owner in overrides
    affected = {p.lower() for p in paths}
    pending = list(affected)
    while pending:
        child = pending.pop()
        parents = set()
        for index in indexes:
            parents.update(index.get(child, ()))
        if packaged:
            parents.update(owner for owner in packaged.get(child, ()) if not shadowed(owner))
        for owner in parents - affected:
            # A cached GUI definition owns its timeline and animation state.
            # UVSequence holders on ready views can be updated independently.
            if child.endswith(".uvs") and owner.endswith(".gui"):
                continue
            # A USER field of type via.Prefab stores a factory for the path.
            # Refresh that factory without retiring its containing USER.
            if child.endswith(".pfb") and owner.endswith(".user"):
                continue
            affected.add(owner)
            pending.append(owner)
    return affected


class ResourceLinks:
    def __init__(self, baseline=None):
        self.records = {}
        self.packaged = {}
        self.stock_parents = defaultdict(set)
        self.stock_aliases = defaultdict(set)
        with gzip.open(INDEX, "rt", encoding="utf-8") as src:
            for owner, references in json.load(src).items():
                parent = owner.lower()
                self.stock_aliases[parent].add(owner)
                for child in references:
                    key = child.lower()
                    self.stock_parents[key].add(parent)
                    self.stock_aliases[key].add(child)
        if baseline is not None:
            for f in baseline.rglob("*"):
                if f.name.lower().endswith(REFERENCE_SUFFIXES) and f.is_file():
                    self.packaged[f.relative_to(baseline)] = resource_paths(f.read_bytes(), preserve_case=True)
        self.index = ReferenceIndex().updated(self.packaged)

    @property
    def graph(self):
        return self.index.graph

    @property
    def aliases(self):
        return self.index.aliases

    def update(self, root, present, changed=None, contents=None):
        candidates = present.keys() | self.records.keys() if changed is None else changed
        changes, edits = {}, {}
        for f in candidates:
            if not f.name.lower().endswith(REFERENCE_SUFFIXES):
                continue
            old = self.records.get(f)
            relative = f.relative_to(root)
            packaged = self.packaged.get(relative)
            if f in present:
                if old and old[0] == present[f]:
                    continue
                raw = contents.get(f) if contents is not None else None
                refs = resource_paths(raw if raw is not None else f.read_bytes(), preserve_case=True)
                changes[f] = present[f], refs
            elif old is not None:
                refs = packaged
                changes[f] = None
            else:
                continue
            if refs != (old[1] if old else packaged):
                edits[relative] = refs
        if changes:
            records = self.records.copy()
            for file, row in changes.items():
                if row is None:
                    del records[file]
                else:
                    records[file] = row
            self.index, self.records = self.index.updated(edits), records

    def direct_parents(self, path):
        target = path.lower()
        parents = {p for p in self.stock_parents.get(target, ()) if p not in self.graph}
        parents.update(self.index.parents.get(target, ()))
        return parents

    def gui_owners(self, path):
        # EquipChange and Smithy both embed the preview_obj GUI. The live
        # component reports the outer menu as its asset when the menu reopens.
        owners = set()
        pending = [path.lower()]
        while pending:
            for parent in self.direct_parents(pending.pop()):
                if parent.endswith(".gui") and parent not in owners:
                    owners.add(parent)
                    pending.append(parent)
        return sorted(owners)

    def owners(self, path):
        refs = self.graph
        target = path.lower()
        direct = self.direct_parents(target)
        if target.endswith(".rtex"):
            folder, _, name = target.rpartition("/")
            if folder == "camera/texture/rendertarget":
                sequence = PREVIEW_UVS.get(name[:-5].removesuffix("_uw"))
                if sequence:
                    uv_path = f"{folder}/{sequence}.uvs"
                    if uv_path not in refs:
                        direct.add(uv_path)
            return sorted(p for p in direct if p.endswith(".uvs")), {}
        intermediate = {}
        if target.endswith(".tex"):
            for uv in sorted(p for p in direct if p.endswith(".uvs")):
                parents = sorted(p for p in self.direct_parents(uv) if p.endswith(".efx"))
                if parents:
                    intermediate[uv] = parents
        return sorted(p for p in direct if p.endswith((".efx", ".motlist"))), intermediate
