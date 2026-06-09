#!/usr/bin/env python3
"""List kernel mutable global storage covered by the S0c SMP audit.

The scanner is intentionally lexical and conservative. It reports top-level
Swift stored `var` declarations and top-level C mutable definitions. It skips
locals, constants, extern declarations, computed Swift globals, and assembly
labels. The output is stable `path:symbol` text so docs/tests can use it as a
small manifest before the S1/S2 locking and per-CPU conversions start.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
KERNEL = ROOT / "kernel"


def split_top_level_commas(text: str) -> list[str]:
    parts: list[str] = []
    start = 0
    depth = 0
    for i, ch in enumerate(text):
        if ch in "([{":
            depth += 1
        elif ch in ")]}" and depth > 0:
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(text[start:i])
            start = i + 1
    parts.append(text[start:])
    return parts


def strip_line_comment(line: str) -> str:
    # Good enough for this kernel style: top-level global declarations do not put
    # URL-like string literals before the declaration syntax.
    return line.split("//", 1)[0].rstrip()


def strip_gnu_attributes(line: str) -> str:
    out = line
    marker = "__attribute__"
    while marker in out:
        start = out.find(marker)
        paren = out.find("((", start)
        if paren < 0:
            break
        depth = 0
        end = -1
        for i in range(paren, len(out)):
            if out[i] == "(":
                depth += 1
            elif out[i] == ")":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
        if end < 0:
            break
        out = out[:start] + out[end:]
    return out


def swift_globals(path: Path) -> list[str]:
    entries: list[str] = []
    for raw in path.read_text(errors="ignore").splitlines():
        line = strip_line_comment(raw)
        match = re.match(
            r"^(?:(?:private|public|internal|fileprivate)(?:\([^)]*\))?\s+)?var\s+(.+)$",
            line,
        )
        if not match:
            continue
        body = match.group(1).strip()
        eq = body.find("=")
        brace = body.find("{")
        if brace >= 0 and (eq < 0 or brace < eq):
            continue
        for part in split_top_level_commas(body):
            name = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(?::|=|$)", part.strip())
            if name:
                entries.append(f"{path.relative_to(ROOT)}:{name.group(1)}")
    return entries


def c_globals(path: Path) -> list[str]:
    entries: list[str] = []
    for raw in path.read_text(errors="ignore").splitlines():
        if raw[:1].isspace():
            continue
        line = strip_gnu_attributes(strip_line_comment(raw).strip())
        if not line:
            continue
        if line.startswith(("#", "/*", "extern ", "typedef ", "struct ", "enum ")):
            continue
        if "const " in line or "(" in line or ";" not in line:
            continue
        left = line.split(";", 1)[0].split("=", 1)[0]
        left = re.sub(r"\[[^\]]+\]", "", left).replace("*", " ")
        tokens = left.split()
        if len(tokens) >= 2:
            entries.append(f"{path.relative_to(ROOT)}:{tokens[-1]}")
    return entries


def main() -> int:
    entries: set[str] = set()
    for path in sorted(KERNEL.rglob("*")):
        if path.suffix == ".swift":
            entries.update(swift_globals(path))
        elif path.suffix in {".c", ".h"}:
            entries.update(c_globals(path))
    for entry in sorted(entries):
        print(entry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
