"""Read Rise Sunbreak's female/male player shadow MESH rest skeletons."""
import math
import re
import struct
from pathlib import Path


_FILE = re.compile(r"player/mod/([fm])/(bone|pl\d+)/\1_shadow\.mesh(?:\.2109148288)?(?:\.stm)?$")
_MAT = struct.Struct("<16f")
_SKEL = struct.Struct("<II5Q")
_IDENTITY = (1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.)


def _product_matches(first, second, expected):
    return all(math.isclose(sum(first[i * 4 + k] * second[k * 4 + j] for k in range(4)),
                            expected[i * 4 + j], abs_tol=2e-4, rel_tol=2e-4)
               for i in range(4) for j in range(4))


def shadow_path(path):
    """Return (sex, 'bone' or 'plNNN') for a supported logical or physical path."""
    match = _FILE.fullmatch(str(path).replace("\\", "/").lower())
    return match.groups() if match else None


def parse_shadow(raw):
    """Return a joint-name map. Matrices use the file's native row-vector convention."""
    def span(offset, count, stride):
        if offset <= 0 or offset + count * stride > len(raw):
            raise ValueError("Out-of-bounds Rise shadow MESH table")
        return offset

    if len(raw) < 128 or raw[:4] != b"MESH":
        raise ValueError("Missing Rise shadow MESH header")
    version, size = struct.unpack_from("<II", raw, 4)
    if version not in (21061800, 21091000) or size != len(raw):
        raise ValueError("Unsupported or incomplete Rise shadow MESH")
    name_count = struct.unpack_from("<H", raw, 18)[0]
    skel, = struct.unpack_from("<Q", raw, 48)
    name_map, _, strings = struct.unpack_from("<3Q", raw, 104)
    count, _, _, hierarchy, local, world, inverse = _SKEL.unpack_from(raw, span(skel, 1, _SKEL.size))
    if not 0 < count <= name_count or not count <= 4096:
        raise ValueError("Invalid Rise shadow joint count")
    span(name_map, count, 2)
    span(strings, name_count, 8)
    span(hierarchy, count, 16)
    span(local, count, 64)
    span(world, count, 64)
    span(inverse, count, 64)
    names, parents, matrices = [], [], []
    for i in range(count):
        mapped, = struct.unpack_from("<H", raw, name_map + 2 * i)
        if mapped >= name_count:
            raise ValueError("Invalid Rise shadow joint name index")
        offset, = struct.unpack_from("<Q", raw, strings + 8 * mapped)
        span(offset, 1, 1)
        end = raw.find(b"\0", offset, offset + 256)
        if end <= offset:
            raise ValueError("Invalid Rise shadow joint name")
        names.append(raw[offset:end].decode("utf-8"))
        index, parent = struct.unpack_from("<Hh", raw, hierarchy + 16 * i)
        if index != i or not -1 <= parent < count:
            raise ValueError("Invalid Rise shadow joint index or parent")
        parents.append(parent)
        row = [_MAT.unpack_from(raw, base + 64 * i) for base in (local, world, inverse)]
        for m in row:
            if not all(map(math.isfinite, m)) or max(abs(m[idx]) for idx in (3, 7, 11)) > 1e-4 or abs(m[15]-1) > 1e-4:
                raise ValueError("Non-affine Rise shadow joint matrix")
        matrices.append(row)
    if len(set(names)) != count or -1 not in parents:
        raise ValueError("Ambiguous or rootless Rise shadow hierarchy")
    checked = set()
    for i in range(count):
        local_mat, world_mat, inv_mat = matrices[i]
        parent_world = _IDENTITY if parents[i] == -1 else matrices[parents[i]][1]
        if not _product_matches(local_mat, parent_world, world_mat) or not _product_matches(world_mat, inv_mat, _IDENTITY):
            raise ValueError(f"Inconsistent Rise rest and bind matrices for {names[i]}")
        visiting = set()
        owner = i
        while owner != -1 and owner not in checked:
            if owner in visiting:
                raise ValueError("Cyclic Rise shadow hierarchy")
            visiting.add(owner)
            owner = parents[owner]
        checked.update(visiting)
    return {name: {"parent": names[p] if p != -1 else None, "local": local_mat,
                   "world": world_mat, "inverse": inv_mat}
            for name, p, (local_mat, world_mat, inv_mat) in zip(names, parents, matrices)}


def _rest_positions(bones, reference):
    # Per-joint position changes can preserve the rest of the current animation.
    # Rotation/scale and topology changes require a complete engine skeleton bind.
    if bones.keys() != reference.keys() or any(row["parent"] != reference[n]["parent"] for n, row in bones.items()):
        return {"deferred": "Shadow skeleton joint names or parents changed"}
    if any(abs(x - y) > 1e-5 for name, row in bones.items()
           for x, y in zip(row["local"][:12], reference[name]["local"][:12])):
        return {"deferred": "Shadow skeleton joint basis changed"}
    return {"joints": {n: {"parent": row["parent"] or "", "position": row["local"][12:15]}
                       for n, row in bones.items()}}


def shadow_targets(root, changes, current, archives, first_natives):
    """Prepare changed sexes only. Scope selection belongs to the observed in-game outfit."""
    def key(file):
        return shadow_path(Path(file).relative_to(root).as_posix())

    wanted = set()
    for file in changes:
        selected = key(file)
        if selected and (selected[1] == "bone" or first_natives):
            wanted.add(selected[0])
    if not wanted:
        return {}
    loose = {}
    for file in current:
        selected = key(file)
        if not selected or selected[0] not in wanted or (selected[1] != "bone" and not first_natives):
            continue
        prev = loose.get(selected)
        if prev is not None:
            # A foreign explicit platform file and an ordinary file may intentionally differ.
            # Avoid guessing the engine's selected rest data in this case.
            if prev.read_bytes() != Path(file).read_bytes():
                raise ValueError(f"Conflicting shadow MESH variants at {prev} and {file}")
        loose[selected] = Path(file)
    targets = {}
    for sex in sorted(wanted):
        canonical = Path(f"player/mod/{sex}/bone/{sex}_shadow.mesh.2109148288")
        original = archives.read(canonical)
        if original is None:
            raise ValueError(f"Missing packaged player skeleton: {canonical}")
        stock = parse_shadow(original)
        variants = {"bone": _rest_positions(stock, stock)}
        for (source_sex, scope), file in sorted(loose.items()):
            if source_sex == sex:
                variants[scope] = _rest_positions(parse_shadow(file.read_bytes()), stock)
        targets[sex] = variants
    return targets
