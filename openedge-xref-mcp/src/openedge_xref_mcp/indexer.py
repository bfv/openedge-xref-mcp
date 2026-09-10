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
    # str(path) -> mtime, tracked so refresh() can reparse only changed files
    _file_mtimes: dict[str, float] = field(default_factory=dict)
    # str(path) -> source names it contributed, needed to clean up calls/includes on removal
    _sources_by_file: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))

    @classmethod
    def build(cls, root: Path) -> XrefIndex:
        index = cls(root=root)
        index.refresh()
        return index

    def refresh(self) -> dict[str, int]:
        """Rescan the root directory, reparsing only new or modified .xref files.

        Removed files are dropped from the index; unchanged files are left untouched.
        Returns a summary of how many files were added/changed/removed/unchanged.
        """
        current_paths = sorted(self.root.rglob("*.xref"))
        current_by_str = {str(path): path for path in current_paths}
        previous_files = set(self._file_mtimes)
        current_files = set(current_by_str)

        removed = previous_files - current_files
        maybe_changed = previous_files & current_files
        changed = {
            path_str
            for path_str in maybe_changed
            if current_by_str[path_str].stat().st_mtime != self._file_mtimes[path_str]
        }
        added = current_files - previous_files

        self._remove_files(removed | changed)

        for path_str in sorted(added | changed):
            path = current_by_str[path_str]
            for entry in parse_file(path):
                self._add_entry(entry)
                self._sources_by_file[path_str].add(entry.source_name)
            self._file_mtimes[path_str] = path.stat().st_mtime

        self.xref_files = current_paths
        return {
            "added": len(added),
            "changed": len(changed),
            "removed": len(removed),
            "unchanged": len(current_files) - len(added) - len(changed),
        }

    def _remove_files(self, path_strs: set[str]) -> None:
        """Drop every entry/derived-index value that came from the given .xref files."""
        if not path_strs:
            return
        self.entries = [e for e in self.entries if e.xref_file not in path_strs]
        for key in list(self.by_table.keys()):
            filtered = [e for e in self.by_table[key] if e.xref_file not in path_strs]
            if filtered:
                self.by_table[key] = filtered
            else:
                del self.by_table[key]
        for source in list(self.by_source.keys()):
            filtered = [e for e in self.by_source[source] if e.xref_file not in path_strs]
            if filtered:
                self.by_source[source] = filtered
            else:
                del self.by_source[source]

        for path_str in path_strs:
            self._file_mtimes.pop(path_str, None)
            sources = self._sources_by_file.pop(path_str, set())
            for source in sources:
                self.includes.pop(source, None)
                targets = self.calls.pop(source, [])
                for target in targets:
                    callers = self.called_by.get(target.lower())
                    if callers and source in callers:
                        callers.remove(source)
                        if not callers:
                            del self.called_by[target.lower()]

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
