import tempfile
import unittest
import zlib
from pathlib import Path

from rise_pak import RisePak, _ENTRY, _HEADER


ASSET = Path("player/mod/f/pl279/embedded_startup.tex.28")
HASH = 0xd662acec092df8c9
TEX = b"TEX\0\x1c\0\0\0" + b"packaged texture fixture" * 8
ZSTD = bytes.fromhex("28b52ffd24c8250100d8544558001c0000007061636b6167656420746578"
                     "747572652066690200a59d045e5bc6613c1d4a")


def archive(path, payload, codec=0, raw_size=None):
    length = len(payload) if raw_size is None else raw_size
    header = _HEADER.pack(b"KPKA", 4, 0, 0, 1, 0)
    row = _ENTRY.pack(HASH, len(header) + _ENTRY.size, len(payload), length, codec, 0)
    path.write_bytes(header + row + payload)


class RisePakTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.game = Path(self.work.name)
        self.dest = self.game / "private/original"
        self.base = self.game / "re_chunk_000.pak"
        self.reader = RisePak(self.game)

    def test_numbered_patches_and_changed_mounts(self):
        patch2 = self.game / "re_chunk_000.pak.patch_002.pak"
        patch10 = self.game / "re_chunk_000.pak.patch_010.pak"
        archive(self.base, TEX + b"base")
        archive(patch2, TEX + b"patch2")
        self.assertTrue(self.reader.extract(ASSET, self.dest))
        self.assertEqual(self.dest.read_bytes(), TEX + b"patch2")
        archive(patch10, TEX + b"patch10")
        self.assertTrue(self.reader.extract(ASSET, self.dest))
        self.assertEqual(self.dest.read_bytes(), TEX + b"patch10")
        patch10.unlink()
        self.assertTrue(self.reader.extract(ASSET, self.dest))
        self.assertEqual(self.dest.read_bytes(), TEX + b"patch2")

    def test_zstd_and_raw_deflate(self):
        archive(self.base, ZSTD, 2, len(TEX))
        self.assertTrue(self.reader.extract(ASSET, self.dest))
        self.assertEqual(self.dest.read_bytes(), TEX)
        encoder = zlib.compressobj(wbits=-15)
        archive(self.base, encoder.compress(TEX) + encoder.flush(), 1, len(TEX))
        self.assertTrue(self.reader.extract(ASSET, self.dest))
        self.assertEqual(self.dest.read_bytes(), TEX)

    def test_missing_result_leaves_destination(self):
        archive(self.base, TEX)
        self.dest.parent.mkdir()
        self.dest.write_bytes(b"previous")
        self.assertFalse(self.reader.extract(Path("different/name.tex.28"), self.dest))
        self.assertEqual(self.dest.read_bytes(), b"previous")
        with self.assertRaises(ValueError):
            self.reader.extract(Path("../not-relative.tex.28"), self.dest)

    def test_invalid_payload_never_exposes_partial_data(self):
        self.dest.parent.mkdir()
        self.dest.write_bytes(b"previous")
        for codec, payload in [(0, b"BAD!" + TEX[4:]), (1, b"invalid raw deflate"),
                               (2, ZSTD[:-2]), (2, ZSTD + b"extra")]:
            with self.subTest(codec=codec, stored_length=len(payload)):
                archive(self.base, payload, codec, len(TEX))
                with self.assertRaises(ValueError):
                    self.reader.extract(ASSET, self.dest)
                self.assertEqual(self.dest.read_bytes(), b"previous")
                self.assertEqual(list(self.dest.parent.iterdir()), [self.dest])


if __name__ == "__main__":
    unittest.main()
