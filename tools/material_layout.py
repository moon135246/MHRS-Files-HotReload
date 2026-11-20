"""Read the material-facing tables in Rise MDF v23 and MMTR v220427553."""
import json
import struct
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from watcher_runtime import index_path, open_index


@dataclass
class Material:
    name: str
    template: str
    size: int
    parameters: set
    textures: set
    values: dict
    texture_paths: dict


def table(offset, count, stride, low, high):
    if count and not low <= offset <= high - count * stride:
        raise ValueError("Material table outside file")
    return range(offset, offset + count * stride, stride)


def mesh_materials(file):
    """Read the main LOD's material names without reading the vertex buffers."""
    with file.open("rb") as src:
        size = file.stat().st_size

        def read(offset, length):
            if length < 0 or not 0 <= offset <= size - length:
                raise ValueError("Rise MESH material table outside file")
            src.seek(offset)
            data = src.read(length)
            if len(data) != length:
                raise ValueError("Incomplete Rise MESH material table")
            return data

        header = read(0, 128)
        if header[:4] != b"MESH":
            raise ValueError("Invalid Rise MESH header")
        lod, = struct.unpack_from("<Q", header, 24)
        remap, = struct.unpack_from("<Q", header, 96)
        offsets, = struct.unpack_from("<Q", header, 120)
        names, = struct.unpack_from("<H", header, 18)
        if not lod or not remap or not offsets:
            raise ValueError("Mesh has no main material table")
        count = read(lod + 1, 1)[0]
        result = set()
        for index, in struct.iter_unpack("<H", read(remap, 2 * count)):
            if index >= names:
                raise ValueError("Invalid MESH material index")
            address, = struct.unpack("<Q", read(offsets + 8 * index, 8))
            data = read(address, min(4096, size - address))
            end = data.find(b"\0")
            if end <= 0:
                raise ValueError("Invalid MESH material name")
            result.add(data[:end].decode("utf-8"))
        return result


def materials(raw):
    if len(raw) < 16 or raw[:4] != b"MDF\0":
        raise ValueError("Invalid MDF header")
    count = struct.unpack_from("<H", raw, 6)[0]
    if not count or 16 + count * 80 > len(raw):
        raise ValueError("Invalid MDF material count")
    low = 16 + count * 80

    def wide(entry):
        start, = struct.unpack_from("<Q", raw, entry)
        if start < low or start % 2:
            raise ValueError("Invalid MDF string offset")
        end = start
        while end + 2 <= len(raw) and raw[end:end+2] != b"\0\0":
            end += 2
        if end == start or end + 2 > len(raw):
            raise ValueError("Invalid MDF string")
        return raw[start:end].decode("utf-16-le")

    result = []
    for h in range(16, low, 80):
        size, properties, textures = struct.unpack_from("<III", raw, h + 12)
        props, slots = struct.unpack_from("<QQ", raw, h + 40)
        block, = struct.unpack_from("<Q", raw, h + 64)
        if (size or properties) and not low <= block <= len(raw):
            raise ValueError("Material table outside file")
        available = len(raw) - block
        last_value_end = 0
        parameters, values = set(), {}
        for p in table(props, properties, 24, low, len(raw)):
            offset, floats = struct.unpack_from("<II", raw, p + 16)
            width = floats * 4
            end = offset + width
            if not width or end > size:
                raise ValueError("Invalid MDF parameter range")
            if end > available:
                raise ValueError("MDF parameter data outside file")
            last_value_end = max(last_value_end, end)
            name = wide(p)
            parameters.add((name, offset, width))
            values[name] = raw[block + offset:block + end]
        # The declared shader buffer includes 16-byte alignment. The final
        # block can end at its last stored value, without writing the padding.
        if size and size > available and size != ((last_value_end + 15) & ~15):
            raise ValueError("Material table outside file")
        paths = {wide(t): wide(t + 16) if struct.unpack_from("<Q", raw, t + 16)[0] else ""
                 for t in table(slots, textures, 32, low, len(raw))}
        template = wide(h + 72).replace("\\", "/")
        path = PurePosixPath(template)
        if path.is_absolute() or ":" in template or ".." in path.parts or path.suffix.lower() != ".mmtr":
            raise ValueError("Invalid MDF template path")
        result.append(Material(wide(h), template, size, parameters, set(paths), values, paths))
    return result


def unchanged_bindings(previous, current):
    if previous is None:
        return {}
    before = {m.name: m for m in materials(previous)}
    keep = {}
    for m in materials(current):
        old = before.get(m.name)
        if old is not None:
            keep[m.name] = {
                "variables": {k: True for k, v in m.values.items() if old.values.get(k) == v},
                "textures": {k: True for k, v in m.texture_paths.items() if old.texture_paths.get(k) == v},
            }
    return keep


def shader_layout(raw):
    if len(raw) < 16 or raw[:4] != b"SDF\0":
        raise ValueError("Invalid Rise MMTR header")
    targets, programs, end = struct.unpack_from("<HHQ", raw, 4)
    low = 16 + targets * programs * 264
    if not targets or not programs or not low <= end <= len(raw):
        raise ValueError("Invalid MMTR program table")

    def name(entry):
        offset, = struct.unpack_from("<Q", raw, entry)
        if not low <= offset < end:
            raise ValueError("Invalid MMTR name offset")
        stop = raw.find(b"\0", offset, end)
        if stop < 0:
            raise ValueError("Unterminated MMTR name")
        return raw[offset:stop].decode("utf-8")

    sizes, parameters, textures = set(), set(), set()
    # Programs on different render passes frequently share these two tables.
    buffers, resources = set(), set()
    for p in range(16, low, 264):
        buffers.add((struct.unpack_from("<Q", raw, p + 0x70)[0], raw[p + 0xf6]))
        resources.add((struct.unpack_from("<Q", raw, p + 0x90)[0], raw[p + 0xfc]))
    for offset, count in buffers:
        for b in table(offset, count, 32, low, end):
            if name(b) != "UserMaterial":
                continue
            size, count_vars, variables = struct.unpack_from("<IIQ", raw, b + 16)
            sizes.add(size)
            for v in table(variables, count_vars, 16, low, end):
                rel, width = struct.unpack_from("<HH", raw, v + 12)
                if width:
                    if rel + width > size:
                        raise ValueError("MMTR parameter outside UserMaterial")
                    parameters.add((name(v), rel, width))
    for offset, count in resources:
        textures.update(name(r) for r in table(offset, count, 16, low, end))
    return sizes, parameters, textures


class IncompatibleMaterial(ValueError):
    pass


class UnverifiedTemplate(ValueError):
    """An existing slot changed to a packaged shader unavailable for live validation."""


SHADER_INDEX = index_path("rise-16.0.2-shaders.json.gz")


def check_layout(material, layout):
    sizes, parameters, textures = layout
    missing = material.parameters - parameters
    slots = material.textures - textures
    if any(size > material.size for size in sizes) or missing or slots:
        detail = []
        if any(size > material.size for size in sizes):
            detail.append(f"buffer {material.size} bytes, shader needs {max(sizes)}")
        if missing:
            key, offset, width = min(missing)
            detail.append(f"{key} at {offset} ({width} bytes)")
        if slots:
            detail.append(f"texture {min(slots)}")
        raise IncompatibleMaterial(f"{material.name} incompatible with {material.template}: " + ", ".join(detail))


class MaterialValidator:
    def __init__(self, root, baseline=None):
        self.root = root
        self.baseline = baseline
        self.shaders = {}
        with open_index(SHADER_INDEX) as src:
            self.packaged_shaders = {p: (set(sizes), {tuple(v) for v in params}, set(textures))
                                     for p, (sizes, params, textures) in json.load(src).items()}

    def source(self, file):
        candidates = [file]
        if file.name.lower().endswith(".mmtr.220427553"):
            candidates.append(Path(str(file) + ".stm"))
        elif file.name.lower().endswith(".mmtr.220427553.stm"):
            candidates.append(file.with_suffix(""))
        for path in candidates:
            if path.is_file():
                return path
        if self.baseline is not None:
            for path in candidates:
                packaged = self.baseline / path.relative_to(self.root)
                if packaged.is_file():
                    return packaged
        return None

    def layout(self, shader):
        stat = shader.stat()
        signature = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
        entry = self.shaders.get(shader)
        if entry is None or signature != entry[0]:
            entry = signature, shader_layout(shader.read_bytes())
            self.shaders[shader] = entry
        return entry[1]

    def validate(self, file, previous=None):
        slots = materials(file.read_bytes())
        for slot in slots:
            shader = self.source(self.root / (slot.template + ".220427553"))
            if shader:
                check_layout(slot, self.layout(shader))
            elif previous and slot.name in previous and previous[slot.name] != slot.template.lower():
                layout = self.packaged_shaders.get(slot.template.lower())
                if layout is None:
                    raise UnverifiedTemplate(f"{slot.name}: cannot verify new template {slot.template} for a live bind")
                check_layout(slot, layout)
        return {slot.name: slot.template.lower() for slot in slots}
