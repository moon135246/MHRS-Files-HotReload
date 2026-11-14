"""Small, versioned RSZ layouts verified against Rise's live components."""
import math
import struct


CAMERA_TYPE = (0x9EE75BEE, 0xEAE27D80)
PLAYER_MARKER = "gui/01_common/prefab/pl_headmessage.pfb"


def camera_fields(raw):
    if len(raw) < 48 or raw[:4] != b"USR\0" or any(raw[4:16]):
        return None
    root = struct.unpack_from("<Q", raw, 32)[0]
    if root + 52 > len(raw) or raw[root:root+4] != b"RSZ\0":
        return None
    if struct.unpack_from("<4I", raw, root+4) != (16, 1, 2, 0):
        return None
    info, data = struct.unpack_from("<QQ", raw, root+24)
    if info < 52 or root+info+16 > len(raw) or struct.unpack_from("<II", raw, root+info+8) != CAMERA_TYPE:
        return None
    if struct.unpack_from("<I", raw, root+48)[0] != 1 or data < info+16 or root+data+16 != len(raw):
        raise ValueError("Unsupported fixed camera USER layout")
    mode, duration, curve, target = struct.unpack_from("<ifB3xi", raw, root+data)
    if not math.isfinite(duration) or duration < 0 or curve > 1:
        raise ValueError("Invalid fixed camera interpolation")
    return {"_InterpolationType": mode, "_InterpolationTime": duration,
            "_IsCurveInterpolation": bool(curve), "_InterpolationTargetCamera": target}


def marker_time(raw):
    if raw[:4] != b"PFB\0" or len(raw) < 64 or struct.unpack_from("<IIII", raw, 4) != (1, 1, 0, 0):
        raise ValueError("Unsupported player marker prefab")
    rsz = struct.unpack_from("<Q", raw, 48)[0]
    if raw[rsz:rsz+4] != b"RSZ\0" or struct.unpack_from("<4I", raw, rsz+4) != (16, 4, 5, 0):
        raise ValueError("Unsupported player marker object table")
    info, data = struct.unpack_from("<QQ", raw, rsz+24)
    types = struct.unpack_from("<8I", raw, rsz+info+8)
    if types != (0xC902A417,0x0CE8A1F8,0xDFAC3046,0x239D8ECD,
                 0x25F55EB4,0x6E83E485,0x22544284,0x126F9274):
        raise ValueError("Unexpected player marker components")
    start = rsz + data
    name = ("PlHeadMessage" + "\0").encode("utf-16-le")
    if struct.unpack_from("<I", raw, start)[0] != len(name)//2 or raw[start+4:start+4+len(name)] != name:
        raise ValueError("Unexpected player marker root")
    tag = (start + 4 + len(name) + 3) & ~3
    if raw[tag:tag+6] != b"\1\0\0\0\0\0":
        raise ValueError("Unsupported player marker tag")
    offset = tag + 8
    value = struct.unpack_from("<f", raw, offset)[0]
    if not math.isfinite(value) or (value < 0 and value != -1):
        raise ValueError("Invalid prefab time scale")
    return offset, value


def marker_diff(previous, current):
    offset, old = marker_time(previous)
    new_offset, new = marker_time(current)
    if offset != new_offset or previous[:offset] != current[:offset] or previous[offset+4:] != current[offset+4:]:
        raise ValueError("Only root TimeScale is supported for this prefab")
    return {} if old == new else {"TimeScale": new}


def prefab_root_fields(raw):
    """Locate the first serialized GameObject, checking the object index and CRC."""
    if len(raw) < 68 or raw[:4] != b"PFB\0" or not struct.unpack_from("<I", raw, 4)[0]:
        raise ValueError("Expected Rise prefab")
    obj, parent = struct.unpack_from("<ii", raw, 56)
    start = struct.unpack_from("<Q", raw, 48)[0]
    if obj != 0 or parent != -1 or raw[start:start+4] != b"RSZ\0" or start + 52 > len(raw):
        raise ValueError("Unsupported prefab root table")
    version, roots, instances, _ = struct.unpack_from("<4I", raw, start+4)
    info, data = struct.unpack_from("<QQ", raw, start+24)
    if (version != 16 or not 0 < roots < instances or info < 48 + roots*4 or
            data < info+8*instances or start+data+4 > len(raw) or
            struct.unpack_from("<I", raw, start+48)[0] != 1 or
            struct.unpack_from("<II", raw, start+info+8) != (0xC902A417, 0x0CE8A1F8)):
        raise ValueError("Unsupported serialized GameObject layout")
    cursor = start + data
    for _ in range(2):  # Name, Tag
        cursor = (cursor+3) & ~3
        count = struct.unpack_from("<I", raw, cursor)[0]
        cursor += 4 + count*2
        if count > 65536 or cursor > len(raw) or (count and raw[cursor-2:cursor] != b"\0\0"):
            raise ValueError("Invalid prefab root string")
    update, draw = struct.unpack_from("<BB", raw, cursor)
    time = (cursor+5) & ~3
    scale = struct.unpack_from("<f", raw, time)[0]
    if max(update, draw) > 1 or not math.isfinite(scale) or (scale < 0 and scale != -1):
        raise ValueError("Invalid prefab root properties")
    return {"UpdateSelf": (cursor, 1, bool(update)), "DrawSelf": (cursor+1, 1, bool(draw)),
            "TimeScale": (time, 4, scale)}


def prefab_root_diff(previous, current):
    old, new = prefab_root_fields(previous), prefab_root_fields(current)
    remaining, edits = bytearray(current), {}
    for key, (offset, size, value) in new.items():
        if old[key][:2] != (offset, size):
            raise ValueError("Prefab layout changed")
        if value != old[key][2]:
            remaining[offset:offset+size] = previous[offset:offset+size]
            edits[key] = value
    if remaining != previous:
        raise ValueError("Edit includes unsupported prefab fields or structure")
    return edits
