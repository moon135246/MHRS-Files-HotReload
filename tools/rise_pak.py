"""Read versioned files from the mounted-style PC Rise main chunks and numbered patches."""
import os
import re
import struct
import tempfile
import zlib
from pathlib import Path


_HEADER = struct.Struct("<4sBBHII")
_ENTRY = struct.Struct("<6Q")
_HASH = struct.Struct("<Q")
_NAME = re.compile(r"re_chunk_(\d+)\.pak(?:\.patch_(\d+)\.pak)?", re.I)
_MASK = 0xffffffff
# The v4 KPKA table uses the format's fixed public modulus and a per-archive 128-byte field.
_TABLE_MODULUS = int(
    "159698812988050218931858239943049262341923379380497049607963099060350749796841519254496552755248"
    "247329341478707377115125501762531718759783782383570809803402506531457975457952012594520782163709"
    "189669755418441371452643663587642874518466328131049057000622627886084167490189664122550047644173"
    "530214666260708854653")


def _rotate(value, count):
    return ((value << count) | (value >> (32 - count))) & _MASK


def _murmur(text):
    data = text.encode("utf-16le")
    value = _MASK
    for i in range(0, len(data), 4):
        block = int.from_bytes(data[i:i + 4], "little")
        block = _rotate((block * 0xcc9e2d51) & _MASK, 15)
        value ^= (block * 0x1b873593) & _MASK
        if i + 4 <= len(data):
            value = (_rotate(value, 13) * 5 + 0xe6546b64) & _MASK
    value ^= len(data)
    value = ((value ^ (value >> 16)) * 0x85ebca6b) & _MASK
    value = ((value ^ (value >> 13)) * 0xc2b2ae35) & _MASK
    return value ^ (value >> 16)


def _name_hash(path):
    return (_murmur(path.upper()) << 32) | _murmur(path.lower())


def _read(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError(f"Truncated Rise PAK: {stream.name}")
    return data


def _decode_table(data, field):
    key = pow(int.from_bytes(field, "little"), 65537, _TABLE_MODULUS).to_bytes(128, "little")
    # The three periods 32, 29 and 256 repeat every 7,424 bytes.
    pad = bytes((i + key[i % 32] * key[i % 29]) & 255 for i in range(7424))
    result = bytearray(data)
    unit = int.from_bytes(pad, "little")
    for start in range(0, len(data), len(pad)):
        block = data[start:start + len(pad)]
        mask = unit if len(block) == len(pad) else int.from_bytes(pad[:len(block)], "little")
        result[start:start + len(block)] = (int.from_bytes(block, "little") ^ mask).to_bytes(len(block), "little")
    return result


class _Index:
    def __init__(self, stream, size):
        signature, version, minor, flags, count, _ = _HEADER.unpack(_read(stream, _HEADER.size))
        if (signature, version, minor) != (b"KPKA", 4, 0) or flags not in (0, 8):
            raise ValueError(f"Unsupported Rise PAK header: {stream.name}")
        length = count * _ENTRY.size
        self.start = _HEADER.size + length + (128 if flags else 0)
        if self.start > size:
            raise ValueError(f"Invalid Rise PAK entry count: {stream.name}")
        data = _read(stream, length)
        self.table = _decode_table(data, _read(stream, 128)) if flags else data
        self.count = count
        self.unsorted = None
        last = 0
        for pos in range(0, length, _ENTRY.size):
            key, = _HASH.unpack_from(self.table, pos)
            if key < last:
                # Managers can disable a name in place. Preserve lookup of all remaining entries.
                self.unsorted = {_HASH.unpack_from(self.table, i)[0]: i
                                 for i in range(0, length, _ENTRY.size)}
                break
            last = key

    def find(self, hashed):
        if self.unsorted is not None:
            pos = self.unsorted.get(hashed)
            return None if pos is None else _ENTRY.unpack_from(self.table, pos)
        low, high = 0, self.count
        while low < high:
            mid = (low + high) // 2
            pos = mid * _ENTRY.size
            key, = _HASH.unpack_from(self.table, pos)
            if key == hashed:
                return _ENTRY.unpack_from(self.table, pos)
            if key < hashed:
                low = mid + 1
            else:
                high = mid
        return None


def _zstd(data, size):
    try:
        from _mhrs_pak import decompress
    except ImportError:
        try:
            import zstandard
        except ImportError as exc:
            raise RuntimeError("Install zstandard to read compressed Rise PAK files in source mode") from exc
        try:
            length = zstandard.frame_content_size(data)
            if length >= 0 and length != size:
                raise ValueError("Zstd frame length disagrees with the Rise PAK entry")
            return zstandard.ZstdDecompressor().decompress(data, max_output_size=size, allow_extra_data=False)
        except zstandard.ZstdError as exc:
            raise ValueError("Invalid Zstd frame in Rise PAK") from exc
    return decompress(data, size)


_PREFIXES = {".mesh": b"MESH", ".mdf2": b"MDF\0", ".tex": b"TEX\0", ".mmtr": b"SDF\0",
             ".chain": b"\x30\0\0\0chan", ".jcns": b"\x15\0\0\0jcns", ".user": b"USR\0",
             ".mot": b"\xef\x01\0\0mot "}


class RisePak:
    def __init__(self, game_dir):
        self.game_dir = Path(game_dir)
        self.indexes = {}

    def _archives(self):
        matches = []
        for path in self.game_dir.glob("re_chunk_*.pak"):
            match = _NAME.fullmatch(path.name)
            if match:
                chunk, patch = match.groups()
                matches.append((patch is not None, int(chunk), int(patch or 0), path))
        return [item[-1] for item in sorted(matches, reverse=True)]

    def read(self, relative_to_natives_stm: Path) -> bytes | None:
        relative = Path(relative_to_natives_stm)
        if relative.anchor or not relative.parts or ".." in relative.parts:
            raise ValueError("Expected a relative natives/stm file path")
        name = _name_hash("natives/stm/" + relative.as_posix())
        for archive in self._archives():
            with archive.open("rb") as stream:
                stat = os.fstat(stream.fileno())
                stamp = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
                prior = self.indexes.get(archive)
                if not prior or prior[0] != stamp:
                    prior = self.indexes[archive] = (stamp, _Index(stream, stat.st_size))
                index = prior[1]
                entry = index.find(name)
                if entry is None:
                    continue
                _, offset, stored, size, flags, _ = entry
                stored = stored or size
                if offset < index.start or offset + stored > stat.st_size or size > 2**31 - 1:
                    raise ValueError(f"Invalid payload bounds in {archive.name}: {relative}")
                if flags & 0xff0000 or (flags & 15) not in (0, 1, 2):
                    raise ValueError(f"Unsupported Rise PAK payload format: {flags:#x}")
                stream.seek(offset)
                payload = _read(stream, stored)
            method = flags & 15
            if method == 1:
                decoder = zlib.decompressobj(-zlib.MAX_WBITS)
                try:
                    payload = decoder.decompress(payload, size + 1)
                except zlib.error as exc:
                    raise ValueError(f"Invalid deflate payload: {relative}") from exc
                if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
                    raise ValueError(f"Invalid deflate payload: {relative}")
            elif method == 2:
                payload = _zstd(payload, size)
            suffixes = relative.name.lower().split(".")
            prefix = _PREFIXES.get("." + suffixes[-2], b"") if len(suffixes) >= 3 else b""
            if len(payload) != size or not payload.startswith(prefix):
                raise ValueError(f"Invalid resource size or header in {archive.name}: {relative}")
            return payload
        return None

    def extract(self, relative_to_natives_stm: Path, destination: Path) -> bool:
        payload = self.read(relative_to_natives_stm)
        if payload is None:
            return False
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        staged = tempfile.NamedTemporaryFile(dir=destination.parent, delete=False)
        stage = Path(staged.name)
        try:
            with staged:
                staged.write(payload)
            stage.replace(destination)
        finally:
            stage.unlink(missing_ok=True)
        return True
