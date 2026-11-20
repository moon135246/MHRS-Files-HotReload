"""Select physical loose/PAK files for the equipment ResourceManager's platform lookup."""
from contextlib import contextmanager
import tempfile
from pathlib import Path

from equipment_physics import is_equipment_physics
from file_changes import FileChangeTimes
from resource_links import logical_path


class EquipmentSources:
    def __init__(self, root, platforms, archives, startup, baseline=None):
        self.root = root
        self.platforms = platforms
        self.archives = archives
        self.baseline = baseline
        self.startup = set(startup)
        self.staged = set()
        self.packaged = set()
        self.stream_headers = set()
        self.times = FileChangeTimes()
        self.initial_textures = {f: (state, self.times.read(f)) for f, state in startup.items()
                                 if f.name.lower().endswith(".tex.28")}

    def provenance(self, affected, current):
        dirs = {path.rpartition("/")[0] for path in affected
                if path.startswith("player/mod/") and path.endswith((".mesh", ".mdf2", ".chain"))}
        if not dirs:
            return [], []
        def names(files):
            result = []
            for file in files:
                if file.name.lower().endswith((".mesh.2109148288", ".chain.48")):
                    path = logical_path(self.root, file).lower()
                    if path.rpartition("/")[0] in dirs:
                        result.append(path)
            return sorted(result)
        return names(self.startup), names(current)

    def original(self, file):
        if self.baseline is not None:
            baseline = self.baseline / file.relative_to(self.root)
            if baseline.is_file():
                return baseline.read_bytes()
        if file in self.packaged and not file.exists():
            return Path(str(file) + ".stm").read_bytes()
        # A cold installation has no on-disk original. The previous live
        # helmet can still expose the mod's fields while the new USER loads.
        path = logical_path(self.root, file).lower()
        if is_equipment_physics(path) or (path.startswith("player/mod/") and path.endswith(".mdf2")):
            return self.archives.read(file.relative_to(self.root))
        return None

    def _stream_headers(self, paths, current, textures):
        headers = set()
        for file, path in paths.items():
            if not path.startswith("streaming/") or not path.endswith(".tex"):
                continue
            ordinary = path.removeprefix("streaming/")
            if not ordinary.startswith("player/mod/") and ordinary not in textures and file not in self.staged:
                continue
            header = self.root.joinpath(*file.relative_to(self.root).parts[1:])
            if file in current or file in self.startup:
                headers.add(header)
            elif header in self.stream_headers:
                self.platforms.discard([header])
                self.staged.discard(header)
                self.packaged.discard(header)
                self.stream_headers.discard(header)
        return headers

    def _unchanged_startup_texture(self, file, current):
        if file not in self.initial_textures or file not in current or file in self.staged:
            return False
        initial, stamp = self.initial_textures[file]
        return current[file] == initial or (current[file][0] == initial[0] and stamp is not None
                                            and self.times.read(file) == stamp)

    def prepare(self, paths, current, affected, targets, links, previous, live_graph, physical_paths,
                *, texture_edits=False, digests=None):
        armor_mdfs = {p for p in affected if p.startswith("player/mod/") and p.endswith(".mdf2")}
        textures = {texture for mdf in armor_mdfs for graph in (links.graph, previous.graph, live_graph)
                    for texture in graph.get(mdf, ()) if texture.endswith(".tex")}
        textures.update(p for p in targets if p.endswith(".tex")
                        and armor_mdfs.intersection(links.stock_parents.get(p, ())))
        if texture_edits:
            # The MDF itself has not changed. Keep the established cache
            # generations for the textures outside this edit.
            textures.intersection_update(targets)
        headers = self._stream_headers(paths, current, textures)
        candidates = set(paths) | headers
        for path in affected | textures:
            file = physical_paths.get(path)
            if file and (file in current or file in self.packaged):
                candidates.add(file)
            if path.endswith(".tex") and not path.startswith("streaming/"):
                stream = physical_paths.get("streaming/" + path)
                if stream in current:
                    candidates.add(stream)
        selected = set()
        for file in candidates:
            if not self.platforms.supports(file):
                continue
            key = logical_path(self.root, file).lower().removeprefix("streaming/")
            if key.endswith((".chain", ".user")) and not is_equipment_physics(key):
                continue
            if file not in headers and self._unchanged_startup_texture(file, current):
                continue
            if ((file in paths and key.endswith(".mot"))
                    or (key.startswith("player/mod/") and key in affected) or key in textures
                    or (file in paths and file in self.staged)):
                selected.add(file)

        # A positive ordinary-file lookup from startup can survive removal.
        # Likewise a streaming-only mod needs the PAK's ordinary TEX header.
        needs_pak = {f for f in selected if f not in current and
                     (f in self.startup or f in headers or f in self.packaged)}
        ready = self._stage_packages(needs_pak)
        loose = self.platforms.prepare(selected - ready, digests=digests)
        self.packaged.difference_update(loose)
        ready.update(loose)
        self.stream_headers.update(f for f in headers & ready if f not in paths
                                   and (f not in current or f in self.initial_textures))
        self.stream_headers.difference_update(paths)
        self.staged.difference_update(selected - ready)
        self.staged.update(ready)
        names = sorted(logical_path(self.root, f) for f in ready
                       if not logical_path(self.root, f).lower().startswith("streaming/"))
        return selected, ready, names

    @contextmanager
    def vertex_source(self, file, stock, installed):
        # A cold removal has no ordinary file. Explicitly select the PAK copy
        # so another installer cannot redirect a pending ordinary resource read.
        with tempfile.TemporaryDirectory() as directory:
            package = None
            if not installed:
                if file.exists():
                    yield None
                    return
                package = Path(directory) / "mesh"
                package.write_bytes(stock)
            with self.platforms.pin_copy(file, package) as stream:
                if stream:
                    self.staged.add(file)
                    if file.exists():
                        self.packaged.discard(file)
                    else:
                        self.packaged.add(file)
                yield stream

    @contextmanager
    def stock_mesh_source(self, file):
        if file.exists():
            yield None
            return
        # Startup removals may already have an owned PAK alias. Only a
        # genuinely missing, worn mesh from a cold installation needs one.
        if file not in self.packaged and not Path(str(file) + ".stm").exists():
            self.staged.update(self._stage_packages({file}, transfer=True))
        if file in self.packaged and not file.exists():
            with self.platforms.pin_package(file) as stream:
                yield stream
        else:
            yield None

    def _stage_packages(self, files, *, transfer=False):
        ready = set()
        if files:
            with tempfile.TemporaryDirectory(dir=self.platforms.state if transfer else None) as directory:
                for i, file in enumerate(sorted(files)):
                    dest = Path(directory) / str(i)
                    try:
                        available = self.archives.extract(file.relative_to(self.root), dest)
                    except (RuntimeError, ValueError):
                        if not transfer:
                            raise
                        # This optional stock-generation proof must not prevent
                        # the engine's ordinary reload of an unsupported PAK.
                        available = False
                    if available:
                        ready.update(self.platforms.prepare_from_package({file: dest}, transfer=transfer))
                    dest.unlink(missing_ok=True)
            self.packaged.difference_update(files)
            self.packaged.update(f for f in ready if not f.exists())
        return ready
