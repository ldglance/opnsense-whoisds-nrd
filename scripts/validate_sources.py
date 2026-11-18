#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate static OPNsense XML, PHP, and embedded Volt JavaScript source."""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def run(command: list[str], *, input_text: str | None = None) -> None:
    result = subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}")
    if result.stdout.strip():
        print(result.stdout.rstrip())


def main() -> int:
    xml_files = sorted(SRC.rglob("*.xml"))
    if not xml_files:
        raise RuntimeError("no OPNsense XML source files found")
    for path in xml_files:
        ET.parse(path)
    print(f"XML: parsed {len(xml_files)} file(s)")

    php = shutil.which("php")
    if not php:
        raise RuntimeError("php CLI is required for PHP syntax validation")
    php_files = sorted(SRC.rglob("*.php"))
    for path in php_files:
        run([php, "-l", str(path)])
    print(f"PHP: linted {len(php_files)} file(s)")

    node = shutil.which("node")
    if not node:
        raise RuntimeError("Node.js is required for Volt JavaScript syntax validation")
    volt_files = sorted(SRC.rglob("*.volt"))
    if not volt_files:
        raise RuntimeError("no Volt view files found")
    script_count = 0
    for path in volt_files:
        source = path.read_text(encoding="utf-8")
        scripts = re.findall(r"<script\b[^>]*>(.*?)</script\s*>", source, flags=re.I | re.S)
        for index, script in enumerate(scripts, start=1):
            with tempfile.NamedTemporaryFile("w", suffix=".js", encoding="utf-8", delete=False) as handle:
                handle.write(script)
                temp_path = Path(handle.name)
            try:
                run([node, "--check", str(temp_path)])
            finally:
                temp_path.unlink(missing_ok=True)
            script_count += 1
    print(f"JavaScript: syntax-checked {script_count} embedded script block(s) across {len(volt_files)} Volt file(s)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ET.ParseError) as exc:
        print(f"source validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
