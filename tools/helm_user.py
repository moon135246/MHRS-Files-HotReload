"""Decode the Rise .user.2 PlayerUserDataPartsHelm layout for in-place field diffs."""
import math
import struct

HAIR = (0x171C076A, 0x22C61231)
FACE = (0x78F9B9B9, 0x269102CE)
HELM = (0x3EA836D2, 0xD2694902)


def decode(raw):
    if raw[:4] != b"USR\0" or any(raw[4:16]):
        raise ValueError("Unsupported USER header or external references")
    r = struct.unpack_from("<Q", raw, 32)[0]
    if raw[r:r+4] != b"RSZ\0" or struct.unpack_from("<II", raw, r+4) != (16, 1):
        raise ValueError("Expected one RSZ v16 root")
    count, externals = struct.unpack_from("<II", raw, r+12)
    info, data = struct.unpack_from("<QQ", raw, r+24)
    root = struct.unpack_from("<I", raw, r+48)[0]
    if externals or not 1 < count <= 2048 or root != count-1 or info < 52 or data < info+8*count:
        raise ValueError("Unsupported helm object table")
    cursor = r+data

    def take(fmt, alignment):
        nonlocal cursor
        cursor = (cursor+alignment-1) & -alignment
        value = struct.unpack_from(fmt, raw, cursor)[0]
        cursor += struct.calcsize(fmt)
        return value

    def length():
        n = take("<I", 4)
        if n > 4096:
            raise ValueError("Invalid array length")
        return n

    objects = {}
    face = None
    for index in range(1, count):
        kind = struct.unpack_from("<II", raw, r+info+8*index)
        if kind == HAIR:
            shape = [take("<f", 4) for _ in range(length())]
            if not all(map(math.isfinite, shape)):
                raise ValueError("Non-finite hair shape")
            objects[index] = ("hair", shape, take("<i", 4), take("<?", 1), take("<?", 1))
        elif kind == FACE:
            objects[index] = ("face", take("<?", 1), take("<?", 1))
        elif kind == HELM and index == root:
            hair = [take("<I", 4) for _ in range(length())]
            face = take("<I", 4)
            if length() or cursor != len(raw):
                raise ValueError("Unsupported chain remap list or trailing data")
        else:
            raise ValueError("Unsupported helm USER instance type")
    if root in objects or not objects.get(face) or objects[face][0] != "face":
        raise ValueError("Invalid helm root")
    fields = {("face", -1, name, -1): val for name, val in zip(("FullFace", "FullBody"), objects[face][1:])}
    for i, ref in enumerate(hair):
        if ref not in objects or objects[ref][0] != "hair":
            raise ValueError("Invalid hair entry")
        _, shape, hide_parts, hide, stop = objects[ref]
        for j, value in enumerate(shape):
            fields["hair", i, "HairShapeData", j] = value
        for field, value in (("HairDispOffParts", hide_parts), ("HairDispOff", hide), ("HairChainStop", stop)):
            fields["hair", i, field, -1] = value
    return fields


def diff(before, after):
    if before.keys() != after.keys():
        raise ValueError("Changing helm USER array lengths requires rebuilding the object")
    return [dict(section=s, index=i, field=f, element=j, value=v)
            for (s, i, f, j), v in after.items() if before[s, i, f, j] != v]
