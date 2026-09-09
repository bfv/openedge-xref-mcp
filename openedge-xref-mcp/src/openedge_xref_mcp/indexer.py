"""In-memory index built from a directory tree of .xref files."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from .models import XrefEntry
from .parser import extract_call_target, extract_table_field, parse_file


@dataclass
class XrefIndex:
    root: Path
    entries: list[XrefEntry] = field(default_factory=list)
    by_source: dict[str, list[XrefEntry]] = field(default_factory=lambda: defaultdict(list))
    by_table: dict[str, list[XrefEntry]] = field(default_factory=lambda: defaultdict(list))
    calls: dict[str, list[str]] = field(default_factory=lambda: defaultdict(list))
    called_by: dict[str, list[str]] = field(default_factory=lambda: defaultdict(list))
    includes: dict[str, list[str]] = field(default_factory=lambda: defaultdict(list))
    xref_files: list[Path] = field(default_factory=list)

    @classmethod
    def build(cls, root: Path) -> XrefIndex:
        index = cls(root=root)
        index.xref_files = sorted(root.rglob("*.xref"))
        for path in index.xref_files:
            for entry in parse_file(path):
                index._add_entry(entry)
        return index

    def _add_entry(self, entry: XrefEntry) -> None:
        self.entries.append(entry)
        self.by_source[entry.source_name].append(entry)

        if entry.is_table_reference:
            table, _field = extract_table_field(entry)
            if table:
                self.by_table[table.lower()].append(entry)

        if entry.is_include:
            include_name = entry.detail.strip()
            if include_name and include_name not in self.includes[entry.source_name]:
                self.includes[entry.source_name].append(include_name)

        if entry.is_call:
            target = extract_call_target(entry)
            if target:
                if target not in self.calls[entry.source_name]:
                    self.calls[entry.source_name].append(target)
                caller = entry.source_name
                if caller not in self.called_by[target.lower()]:
                    self.called_by[target.lower()].append(caller)

    def programs(self) -> list[str]:
        return sorted(self.by_source)

    def get_program_entries(self, source_name: str) -> list[XrefEntry]:
        return self.by_source.get(source_name, [])

    def find_table_usage(self, table: str, field_name: str | None = None) -> list[XrefEntry]:
        matches = self.by_table.get(table.lower(), [])
        if field_name is None:
            return matches
        results = []
        for entry in matches:
            _, entry_field = extract_table_field(entry)
            if entry_field and entry_field.lower() == field_name.lower():
                results.append(entry)
        return results

    def find_callers(self, target: str) -> list[str]:
        return self.called_by.get(target.lower(), [])

    def find_callees(self, source_name: str) -> list[str]:
        return self.calls.get(source_name, [])

    def get_includes(self, source_name: str) -> list[str]:
        return self.includes.get(source_name, [])

    def search(self, text: str, xref_type: str | None = None) -> list[XrefEntry]:
        needle = text.lower()
        results = []
        for entry in self.entries:
            if xref_type and entry.xref_type != xref_type.upper():
                continue
            if needle in entry.detail.lower() or needle in entry.source_name.lower():
                results.append(entry)
        return results
