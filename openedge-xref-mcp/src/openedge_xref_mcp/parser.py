"""Parser for OpenEdge ABL COMPILE ... XREF text output files.

Each line of an XREF file has the format (see the COMPILE statement reference):

    source-name file-name line-number xref-type xref-information

Fields are whitespace separated, but xref-information may itself contain
spaces, so it is captured as the remainder of the line.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Iterator
from pathlib import Path

from .models import XrefEntry

_LINE_RE = re.compile(
    r"""^
    (?P<source_name>\S+)\s+
    (?P<file_name>\S+)\s+
    (?P<line_number>\d+)\s+
    (?P<xref_type>[A-Z][A-Z0-9-]*)\s*
    (?P<detail>.*)
    $""",
    re.VERBOSE,
)


def parse_line(line: str, xref_file: str) -> XrefEntry | None:
    """Parse a single XREF line, returning None for blank/unrecognized lines."""
    stripped = line.rstrip("\n")
    if not stripped.strip():
        return None
    match = _LINE_RE.match(stripped)
    if not match:
        return None
    return XrefEntry(
        source_name=match.group("source_name"),
        file_name=match.group("file_name"),
        line_number=int(match.group("line_number")),
        xref_type=match.group("xref_type"),
        detail=match.group("detail").strip(),
        xref_file=xref_file,
    )


def parse_text(text: str, xref_file: str) -> Iterator[XrefEntry]:
    for line in text.splitlines():
        entry = parse_line(line, xref_file)
        if entry is not None:
            yield entry


def parse_file(path: Path) -> list[XrefEntry]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return list(parse_text(text, str(path)))


def parse_files(paths: Iterable[Path]) -> list[XrefEntry]:
    entries: list[XrefEntry] = []
    for path in paths:
        entries.extend(parse_file(path))
    return entries


_DB_TABLE_FIELD_RE = re.compile(
    r"^(?:\[?(?:DATA-MEMBER|INHERITED-DATA-MEMBER)]?\s+)?"
    r"(?P<table>[\w.]+)"
    r"(?:\s+(?P<field>[A-Za-z_][\w-]*))?"
)


def extract_table_field(entry: XrefEntry) -> tuple[str | None, str | None]:
    """Best-effort extraction of (table, field) from a table-reference entry.

    Handles ACCESS / UPDATE / CREATE / DELETE / REFERENCE / SEARCH / SORT-ACCESS
    entries, e.g. "sports2020.Order OrderNum" -> ("sports2020.Order", "OrderNum").
    Returns (None, None) when the detail does not look like a table reference
    (for example class property access such as "PUBLIC-PROPERTY foo:Bar").
    """
    detail = entry.detail
    if not detail or ":" in detail.split(" ", 1)[0]:
        return None, None
    first_token = detail.split(",", 1)[0].split(" ", 1)[0]
    if first_token in (
        "PUBLIC-PROPERTY",
        "PACKAGE-PROTECTED-PROPERTY",
        "PACKAGE-PRIVATE-PROPERTY",
        "PROTECTED-PROPERTY",
        "SHARED",
        "PUBLIC-DATA-MEMBER",
        "PACKAGE-PROTECTED-DATA-MEMBER",
        "PACKAGE-PRIVATE-DATA-MEMBER",
        "INHERITED-DATA-MEMBER",
    ):
        return None, None
    match = _DB_TABLE_FIELD_RE.match(detail)
    if not match:
        return None, None
    return match.group("table"), match.group("field")


def extract_call_target(entry: XrefEntry) -> str | None:
    """Best-effort extraction of the called program/method for RUN/INVOKE/NEW."""
    if entry.xref_type not in ("RUN", "INVOKE", "NEW"):
        return None
    return entry.detail.split(",", 1)[0].strip()
