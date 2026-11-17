import struct
import tempfile
import unittest
from pathlib import Path

from rise_shadow import parse_shadow, shadow_path, shadow_targets


def sample_mesh(y, version=21091000, parent=0):
    raw = bytearray(640)
    struct.pack_into("<4sII", raw, 0, b"MESH", version, len(raw))
    struct.pack_into("<H", raw, 18, 2)
    struct.pack_into("<Q", raw, 48, 128)
    struct.pack_into("<3Q", raw, 104, 208, 0, 216)
    struct.pack_into("<II5Q", raw, 128, 2, 0, 0, 176, 256, 384, 512)
    for i, p in enumerate([-1, parent]):
        struct.pack_into("<Hh", raw, 176 + i*16, i, p)
    struct.pack_into("<2H", raw, 208, 0, 1)
    struct.pack_into("<2Q", raw, 216, 232, 237)
    raw[232:242] = b"Root\0Head\0"
    for base, delta in ((256, y), (384, y), (512, -y)):
        for index in range(2):
            struct.pack_into("<16f", raw, base + 64*index, 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,delta*index,0,1)
    return raw


class ShadowTest(unittest.TestCase):
    def test_readback_and_bounds(self):
        raw = sample_mesh(.125, version=21061800)
        head = parse_shadow(raw)["Head"]
        self.assertEqual(head["parent"], "Root")
        self.assertEqual([head[key][13] for key in ("local", "world", "inverse")], [.125, .125, -.125])
        bad = raw.copy()
        struct.pack_into("<Q", bad, 48, len(raw)-1)
        with self.assertRaisesRegex(ValueError, "Out-of-bounds"):
            parse_shadow(bad)
        struct.pack_into("<f", raw, 512+64+52, 100.)
        with self.assertRaisesRegex(ValueError, "Inconsistent"):
            parse_shadow(raw)
        with self.assertRaisesRegex(ValueError, "Cyclic"):
            parse_shadow(sample_mesh(0, parent=1))

    def test_path_selectors(self):
        self.assertEqual(shadow_path(r"player\mod\M\PL000\m_shadow.mesh.2109148288.stm"), ("m","pl000"))
        self.assertEqual(shadow_path("player/mod/f/bone/f_shadow.mesh"), ("f","bone"))
        self.assertIsNone(shadow_path("player/mod/f/bone/m_shadow.mesh"))
        self.assertIsNone(shadow_path("player/mod/f/pl279/f_helm279.mesh.2109148288"))

    def test_equipment_scope_ordinary_override_and_packaged_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            canon = root / "player/mod/f/bone/f_shadow.mesh.2109148288"
            scoped = root / "player/mod/f/pl279/f_shadow.mesh.2109148288"
            for p, value in ((canon, .25), (scoped, .5)):
                p.parent.mkdir(parents=True)
                p.write_bytes(sample_mesh(value))

            class Pak:
                def read(self, name):
                    if name != canon.relative_to(root):
                        raise AssertionError("No packaged scoped shadow exists")
                    return sample_mesh(.125)

            def heights(changed, current, fn=True):
                spec = shadow_targets(root, changed, current, Pak(), fn)
                return {src: data["joints"]["Head"]["position"][1] for src, data in spec.get("f", {}).items()}

            self.assertEqual(heights([scoped], [canon, scoped], False), {})
            self.assertEqual(heights([canon], [canon, scoped], False), {"bone": .25})
            self.assertEqual(heights([scoped], [canon, scoped]), {"bone": .25, "pl279": .5})
            self.assertEqual(heights([scoped], [canon]), {"bone": .25})
            self.assertEqual(heights([scoped], []), {"bone": .125})

    def test_foreign_conflict_and_basis_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "player/mod/f/pl279/f_shadow.mesh.2109148288"
            path.parent.mkdir(parents=True)
            data = sample_mesh(0)
            for base in (256, 384, 512):
                struct.pack_into("<f", data, base+64, -1)
            path.write_bytes(data)
            class Pak:
                def read(self, _):
                    return sample_mesh(0)
            self.assertIn("deferred", shadow_targets(root, [path], [path], Pak(), True)["f"]["pl279"])
            foreign = Path(str(path) + ".stm")
            foreign.write_bytes(sample_mesh(4))
            with self.assertRaisesRegex(ValueError, "Conflicting"):
                shadow_targets(root, [path], [path, foreign], Pak(), True)


if __name__ == "__main__":
    unittest.main()
