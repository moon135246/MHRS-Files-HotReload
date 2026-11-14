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
