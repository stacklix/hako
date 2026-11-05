#!/usr/bin/env python3
"""Generate comparable iOS build numbers for CI and local delivery."""

import argparse
import os
import time
from pathlib import Path

EPOCH = 1577836800  # 2020-01-01 UTC


def build_number(ordinal):
    major, rest = divmod(ordinal, 10000)
    minor, patch = divmod(rest, 100)
    if not 1 <= major <= 9999:
        raise ValueError("Build number clock is outside the supported range")
    return f"{major}.{minor}.{patch}"


def ordinal_at(seconds, local):
    # Separate CI and local builds made in the same time slot.
    return ((seconds - EPOCH) // 20) * 2 + int(local)


def prepare_local(path, ordinal):
    prefix = "CURRENT_PROJECT_VERSION = "
    if path.exists():
        previous = path.read_text(encoding="utf-8").strip()
        if not previous.startswith(prefix):
            raise ValueError("Expected a generated LocalBuild.xcconfig")
        major, minor, patch = map(int, previous.removeprefix(prefix).split("."))
        ordinal = max(ordinal, major * 10000 + minor * 100 + patch + 2)
    number = build_number(ordinal)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(prefix + number + "\n", encoding="utf-8")
    os.replace(temporary, path)
    return number


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local", action="store_true", help="Write the local Release configuration")
    args = parser.parse_args()
    ordinal = ordinal_at(int(time.time()), args.local)
    if args.local:
        config = Path(__file__).resolve().parents[1] / "Configuration/LocalBuild.xcconfig"
        print(prepare_local(config, ordinal))
    else:
        print(build_number(ordinal))
