#!/usr/bin/env python3
"""Enforce the native client's English catalog and localization contract."""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from pathlib import Path

KEY_RE = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$")
CATALOG_ENTRY_RE = re.compile(r"^\s*'([^']+)':\s*'((?:[^'\\]|\\.)*)'\s*,?\s*$", re.M)
KEY_REFERENCE_RE = re.compile(
    r"(?:VentioText|ventioText)\s*\(\s*['\"]([^'\"]+)['\"]|"
    r"_text\s*\(\s*['\"]([^'\"]+)['\"]"
)
STATIC_TEXT_RE = re.compile(
    r"\b(?:Text|SelectableText)\s*\(\s*(?:text\s*:\s*)?(['\"])(.*?)\1",
    re.S,
)
STATIC_SPAN_RE = re.compile(r"\bTextSpan\s*\(\s*text\s*:\s*(['\"])(.*?)\1", re.S)
STATIC_PROPERTY_RE = re.compile(
    r"\b(?:labelText|helperText|tooltip|semanticLabel)\s*:\s*(['\"])(.*?)\1", re.S
)
# Flutter validators commonly return a sentence directly instead of passing it
# to a Text widget. Catch fixed English sentences there as well; plain status
# codes and technical return constants do not match this pattern.
RETURN_MESSAGE_RE = re.compile(
    r"\breturn\s+(['\"])(?=[A-Z][^'\"\n]*\s)([^'\"\n]*\.[^'\"\n]*)\1"
)
TECHNICAL_TEXT_ALLOWLIST = {
    "", " ", "\\n", "-", "…", "•", "·", ":", "/", "\\", "{", "}", "[", "]",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
}


def _strip_comments(source: str) -> str:
    # Keep quoted strings intact while excluding comments from scans.
    token = re.compile(r"//[^\n]*|/\*[\s\S]*?\*/|'''[\s\S]*?'''|\"\"\"[\s\S]*?\"\"\"|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"")

    def replace(match: re.Match[str]) -> str:
        value = match.group(0)
        return "\n" * value.count("\n") if value.startswith(("//", "/*")) else value

    return token.sub(replace, source)


def validate_catalog(source: str, source_name: str = "English catalog") -> tuple[dict[str, str], list[str]]:
    entries: dict[str, str] = {}
    errors: list[str] = []
    for match in CATALOG_ENTRY_RE.finditer(source):
        key, value = match.groups()
        if key in entries:
            errors.append(f"{source_name}: duplicate key {key}")
        if not KEY_RE.fullmatch(key):
            errors.append(f"{source_name}: invalid stable key {key}")
        if not value.strip():
            errors.append(f"{source_name}: empty English fallback for {key}")
        if any(
            unicodedata.category(character).startswith("L")
            and not unicodedata.name(character, "").startswith("LATIN")
            for character in value
        ):
            errors.append(f"{source_name}: fallback for {key} contains non-English text")
        entries[key] = value
    if not entries:
        errors.append(f"{source_name}: no English catalog entries found")
    return entries, errors


def scan_dart(source: str, source_name: str, catalog_keys: set[str]) -> list[str]:
    code = _strip_comments(source)
    # Interpolated expressions may contain quoted map keys. Remove expression
    # bodies before looking for surrounding fixed UI copy so the scanner does
    # not mistake key names or user data for presentation text.
    presentation_code = re.sub(r"\$\{[^}]*\}|\$[A-Za-z_]\w*", "", code)
    errors: list[str] = []
    for regex in (STATIC_TEXT_RE, STATIC_SPAN_RE, STATIC_PROPERTY_RE, RETURN_MESSAGE_RE):
        for match in regex.finditer(presentation_code):
            value = match.group(2).strip()
            message_text = value.strip()
            if message_text in TECHNICAL_TEXT_ALLOWLIST or not re.search(r"[A-Za-z]", message_text):
                continue
            # Dynamic business values (for example '${record.customerName}') are data;
            # only fixed English surrounding that data is considered UI copy.
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"{source_name}:{line}: hardcoded UI text {value!r}; use a catalog key")
    for match in KEY_REFERENCE_RE.finditer(code):
        key = match.group(1) or match.group(2)
        if match.group(2):
            if source_name != "lib/src/synchronization_page.dart":
                continue
            key = f"native.ui.{key}"
        if "$" in key:
            continue
        if key.startswith("native.ui.") and key not in catalog_keys:
            line = code.count("\n", 0, match.start()) + 1
            errors.append(f"{source_name}:{line}: missing English fallback for {key}")
    return errors


def check(root: Path) -> list[str]:
    catalog_path = root / "lib/src/native_english_messages.dart"
    if not catalog_path.is_file():
        return [f"Missing English catalog: {catalog_path}"]
    entries, errors = validate_catalog(catalog_path.read_text(encoding="utf-8"))
    for path in sorted((root / "lib").rglob("*.dart")):
        if path == catalog_path:
            continue
        errors.extend(scan_dart(path.read_text(encoding="utf-8"), path.relative_to(root).as_posix(), set(entries)))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-root", type=Path, default=Path("packages/ventio_native_client"))
    args = parser.parse_args()
    errors = check(args.client_root.resolve())
    if errors:
        print("Localization gate failed:")
        print("\n".join(f"- {error}" for error in errors))
        return 1
    print("Localization gate passed: English fallback catalog and UI references are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
