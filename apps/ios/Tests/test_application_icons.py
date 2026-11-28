"""Validate child-owned icon declarations and the shared template style."""
from pathlib import Path
import hashlib
import re
import struct
import unittest
import xml.etree.ElementTree as ET
import zlib

APP = Path(__file__).resolve().parents[1] / "Hako"


def read_rgba_png(path):
    """Decode the PNG scanlines so tests check real pixels, without image packages."""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, compressed, texts = 8, bytearray(), {}
    width = height = None
    while offset < len(data):
        length, = struct.unpack_from(">I", data, offset)
        tag = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc, = struct.unpack_from(">I", data, offset + 8 + length)
        assert crc == zlib.crc32(tag + payload), "Corrupt PNG chunk"
        if tag == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            assert (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0), "Expected 8-bit RGBA PNG"
        elif tag == b"IDAT":
            compressed.extend(payload)
        elif tag == b"tEXt":
            key, value = payload.split(b"\x00", 1)
            texts[key.decode("ascii")] = value.decode("ascii")
        offset += length + 12
    raw = zlib.decompress(compressed)
    stride, previous, pixels = width * 4, bytearray(width * 4), bytearray()
    assert len(raw) == height * (stride + 1)
    for row in range(height):
        start = row * (stride + 1)
        method = raw[start]
        current = bytearray(raw[start + 1:start + 1 + stride])
        for index in range(stride):
            left = current[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if method == 0: predictor = 0
            elif method == 1: predictor = left
            elif method == 2: predictor = above
            elif method == 3: predictor = (left + above) // 2
            elif method == 4:
                p = left + above - upper_left
                distances = [abs(p - value) for value in (left, above, upper_left)]
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else: raise AssertionError("Unknown PNG filter")
            current[index] = (current[index] + predictor) & 255
        pixels.extend(current)
        previous = current
    return width, height, pixels, texts


class ApplicationIconTests(unittest.TestCase):
    def test_all_home_modules_own_a_distinct_icon(self):
        modules = list((APP / "Features").glob("*/*ApplicationModule.swift"))
        names, artwork = set(), set()
        for module in modules:
            source = module.read_text(encoding="utf-8")
            match = re.search(r'icon: \.asset\("([^"\n]+)"\)', source)
            if not match:
                continue
            with self.subTest(module=module.name):
                name = match.group(1)
                self.assertNotIn(name, names)
                names.add(name)
                folders = list(module.parent.glob(f"*.xcassets/{name}.imageset"))
                self.assertEqual(len(folders), 1)
                svg_path = folders[0] / "icon.svg"
                self.assertTrue(svg_path.is_file())
                artwork.add(hashlib.sha256(svg_path.read_bytes()).hexdigest())
                svg = ET.parse(svg_path).getroot()
                for key, value in {"viewBox": "0 0 32 32", "width": "32", "height": "32", "stroke-width": "2",
                                   "stroke-linecap": "round", "stroke-linejoin": "round"}.items():
                    self.assertEqual(svg.attrib[key], value)
                for element in svg.iter():
                    self.assertIn(element.tag.rsplit("}", 1)[-1], {"svg", "path", "circle", "rect"})
                    for key in ["fill", "stroke"]:
                        if key in element.attrib:
                            self.assertIn(element.attrib[key], {"none", "#000000"})
        self.assertEqual(len(names), 13)
        self.assertFalse(list((APP / "Features").glob("*/*.application.json")))
        self.assertFalse(list((APP / "Features").glob("*/*.credentials.json")))
        self.assertEqual(len(artwork), 13, "No two child icons may reuse the same artwork")

    def test_shell_uses_one_renderer_without_child_specific_icons(self):
        for name in ["App/HakoApp.swift", "App/Settings/HakoApplicationOrderView.swift", "Shared/Navigation/HakoPinRegistry.swift"]:
            source = (APP / name).read_text(encoding="utf-8")
            self.assertIn("HakoApplicationIcon(", source)
            self.assertNotIn("QinglongLogo", source)
            self.assertNotIn("app.imageAsset", source)
            self.assertNotIn("app.symbol", source)
        renderer = (APP / "Shared/UI/HakoApplicationIcon.swift").read_text(encoding="utf-8")
        self.assertIn(".renderingMode(.template)", renderer)
        self.assertIn('Image(systemName: "square.dashed")', renderer)
        self.assertNotIn("colorScheme", renderer, "Template tint must inherit dynamic foreground style")
        self.assertIn("UIImage(contentsOfFile: url.path)", renderer)
        self.assertIn('name + "Template@3x"', renderer)
        self.assertNotIn("UIImage(named:", renderer, "Runtime template alpha must bypass CAR renditions")

    def test_runtime_pngs_have_real_transparent_artwork(self):
        icons = list((APP / "Features").glob("*/Icons/*Template@3x.png"))
        self.assertEqual(len(icons), 13)
        hashes = set()
        for png in icons:
            with self.subTest(icon=png.name):
                width, height, pixels, texts = read_rgba_png(png)
                self.assertEqual((width, height), (96, 96))
                alpha = pixels[3::4]
                self.assertEqual(alpha[0], 0)
                self.assertEqual(alpha[width - 1], 0)
                self.assertEqual(alpha[-1], 0)
                self.assertGreater(alpha.count(0), width * height // 2, "Opaque rectangle instead of line artwork")
                self.assertGreater(sum(value > 0 for value in alpha), 100, "Empty or missing icon")
                self.assertTrue(any(value == 255 for value in alpha))
                name = png.name.removesuffix("Template@3x.png")
                source, = png.parent.parent.glob(f"*.xcassets/{name}.imageset/icon.svg")
                self.assertEqual(texts["hako-svg-sha256"], hashlib.sha256(source.read_bytes()).hexdigest(),
                                 "SVG changed without regenerating the runtime PNG")
                hashes.add(hashlib.sha256(pixels).hexdigest())
        self.assertEqual(len(hashes), 13)


if __name__ == "__main__":
    unittest.main()
