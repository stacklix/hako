"""Render child-owned SVG artwork to transparent runtime PNGs (requires librsvg)."""
from pathlib import Path
import argparse
import hashlib
import re
import struct
import subprocess
import zlib

APP = Path(__file__).resolve().parents[1] / "Hako"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--renderer", default="rsvg-convert", help="Path to librsvg rsvg-convert")
    args = parser.parse_args()
    count = 0
    for module in sorted((APP / "Features").glob("*/*ApplicationModule.swift")):
        match = re.search(r'icon: \.asset\("([^"\n]+)"\)', module.read_text(encoding="utf-8"))
        if not match:
            continue
        name = match.group(1)
        source, = module.parent.glob(f"*.xcassets/{name}.imageset/icon.svg")
        result = subprocess.run([args.renderer, "--format=png", "--width=96", "--height=96", str(source)],
                                check=True, capture_output=True)
        png = result.stdout
        if not png.startswith(b"\x89PNG\r\n\x1a\n") or png[-8:-4] != b"IEND":
            raise ValueError(f"Renderer did not produce a PNG: {name}")
        # Keep provenance with the generated file so a changed SVG cannot silently
        # leave a stale runtime icon. Runtime uses the PNG, never a CAR rendition.
        payload = b"hako-svg-sha256\x00" + hashlib.sha256(source.read_bytes()).hexdigest().encode("ascii")
        chunk = struct.pack(">I", len(payload)) + b"tEXt" + payload + struct.pack(">I", zlib.crc32(b"tEXt" + payload))
        target = module.parent / "Icons" / (name + "Template@3x.png")
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(png[:-12] + chunk + png[-12:])
        count += 1
    print(f"Rendered {count} transparent application icons at 3x")


if __name__ == "__main__":
    main()
