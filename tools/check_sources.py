#!/usr/bin/env python3
"""Structural checks for the Monkey C sources, without the Garmin SDK.

CI cannot compile Monkey C - the SDK needs a licence, a developer key and
a simulator - so every .mc mistake would otherwise wait for someone to
open VS Code. This catches the classes that are mechanical to detect:

  - unbalanced braces or parentheses (a truncated write)
  - a call to a method that no longer exists on the collaborator
  - `new SomeClass()` where SomeClass isn't defined anywhere
  - Rez.Strings.X that isn't in strings.xml, or is missing its Polish
    translation, or is defined and never used
  - a string loaded into a field nothing reads

It is not a compiler and does not pretend to be. It is the subset of
"would this even build" that costs nothing to run on every push.

Run: python tools/check_sources.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "source"
STRINGS_EN = ROOT / "resources" / "strings" / "strings.xml"
STRINGS_PL = ROOT / "resources-pol" / "strings" / "strings.xml"

# Field name -> the class it holds. Checked wherever the name appears, so
# a rename that misses a call site is caught rather than discovered on a
# watch.
COLLABORATORS = {
    "view": "AedFinderView",
    "client": "AedClient",
    "cache": "AedCache",
    "aedList": "AedList",
    "alerts": "ProximityAlerts",
    "positioning": "Positioning",
    "headingSource": "HeadingSource",
    "renderer": "AedRenderer",
}

# Local names used only inside test modules. Kept separate because
# `list` is a plain Array inside AedList.mc itself.
TEST_LOCALS = {
    "list": "AedList",
    "h": "HeadingSource",
    "f.client": "AedClient",
    "f.alerts": "ProximityAlerts",
}

MODULES = ("AedTiles", "GeoMath", "TextFit", "AedLogo")

# Provided by Toybox, not by this project.
EXTERNAL_CLASSES = {"Menu2", "MenuItem"}

# Referenced by manifest.xml rather than by any .mc file.
MANIFEST_STRINGS = {"AppName"}


def code_only(text: str) -> str:
    """Strips strings first, then comments.

    Order matters: the `//` inside "https://..." is not a comment, and
    treating it as one silently eats the rest of the line - which once
    produced a false unbalanced-brace report.
    """
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    text = re.sub(r"'(?:[^'\\\n]|\\.)*'", "' '", text)
    return re.sub(r"//.*", "", text)


def check() -> list[str]:
    sources = {p.stem: p.read_text(encoding="utf-8") for p in SOURCE.rglob("*.mc")}
    if not sources:
        return [f"no .mc files under {SOURCE}"]

    code = {name: code_only(text) for name, text in sources.items()}

    declared: dict[str, set[str]] = {}
    owner: dict[str, str] = {}
    for name, text in code.items():
        declared[name] = (
            set(re.findall(r"\bfunction\s+(\w+)\s*\(", text))
            | set(re.findall(r"\bconst\s+(\w+)\s*=", text))
        )
        for _, symbol in re.findall(r"\b(class|module)\s+(\w+)", text):
            owner[symbol] = name

    errors: list[str] = []

    for name, text in code.items():
        mapping = dict(COLLABORATORS)
        if name.endswith("Test"):
            mapping.update(TEST_LOCALS)

        for field, cls in mapping.items():
            home = owner.get(cls)
            if home is None:
                continue
            # (?<![\w.]) so `h.` doesn't match the tail of `Math.`
            pattern = r"(?<![\w.])" + re.escape(field) + r"\.(\w+)"
            for member in re.findall(pattern, text):
                if member not in declared[home]:
                    errors.append(f"{name}.mc: {field}.{member} is not declared in {cls}")

        for module, member in re.findall(
            r"(?<![\w.])(" + "|".join(MODULES) + r")\.(\w+)", text
        ):
            home = owner.get(module)
            if home and member not in declared[home]:
                errors.append(f"{name}.mc: {module}.{member} is not declared in {module}")

        for cls in re.findall(r"\bnew\s+([A-Z]\w+)\s*\(", text):
            if "." in cls or cls in EXTERNAL_CLASSES or cls in owner:
                continue
            errors.append(f"{name}.mc: instantiates unknown class {cls}")

        for open_ch, close_ch, label in (("{", "}", "braces"), ("(", ")", "parens")):
            if text.count(open_ch) != text.count(close_ch):
                errors.append(
                    f"{name}.mc: unbalanced {label} "
                    f"({text.count(open_ch)} open, {text.count(close_ch)} close)"
                )

    errors += check_strings(code)
    return errors


def check_strings(code: dict[str, str]) -> list[str]:
    errors = []
    defined = set(re.findall(r'id="(\w+)"', STRINGS_EN.read_text(encoding="utf-8")))
    polish = set(re.findall(r'id="(\w+)"', STRINGS_PL.read_text(encoding="utf-8")))

    used: set[str] = set()
    for text in code.values():
        used |= set(re.findall(r"Rez\.Strings\.(\w+)", text))

    for name in sorted(used - defined):
        errors.append(f"Rez.Strings.{name} is used but not in strings.xml")
    for name in sorted((defined - used) - MANIFEST_STRINGS):
        errors.append(f"string {name!r} is defined but never used")
    for name in sorted(defined - polish):
        errors.append(f"string {name!r} has no Polish translation")

    # A string loaded into a field that nothing reads: the field name
    # appears only in its declaration and the assignment.
    for file_name, text in code.items():
        for match in re.finditer(
            r"(\w+)\s*=\s*WatchUi\.loadResource\(Rez\.Strings\.(\w+)\)", text
        ):
            field = match.group(1)
            if len(re.findall(rf"(?<![\w.]){re.escape(field)}\b", text)) < 3:
                errors.append(
                    f"{file_name}.mc: {field} is loaded from "
                    f"Rez.Strings.{match.group(2)} but never used"
                )
    return errors


def main() -> None:
    errors = check()
    if errors:
        print("source check FAILED:", file=sys.stderr)
        for error in dict.fromkeys(errors):
            print(f"  - {error}", file=sys.stderr)
        raise SystemExit(1)

    files = len(list(SOURCE.rglob("*.mc")))
    print(f"source check ok: {files} Monkey C files, "
          f"cross-references and strings consistent")


if __name__ == "__main__":
    main()
