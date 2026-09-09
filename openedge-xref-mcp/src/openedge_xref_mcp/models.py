"""Data models for parsed OpenEdge XREF entries."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class XrefEntry:
    """A single line of a COMPILE ... XREF output file.

    Format (whitespace separated, see COMPILE statement docs):
        source-name file-name line-number xref-type xref-information
    """

    source_name: str
    file_name: str
    line_number: int
    xref_type: str
    detail: str
    xref_file: str
    """Path of the .xref file this entry was parsed from."""

    @property
    def is_include(self) -> bool:
        return self.xref_type == "INCLUDE"

    @property
    def is_call(self) -> bool:
        return self.xref_type in ("RUN", "INVOKE", "NEW")

    @property
    def is_table_reference(self) -> bool:
        return self.xref_type in (
            "ACCESS",
            "UPDATE",
            "CREATE",
            "DELETE",
            "REFERENCE",
            "SEARCH",
            "SORT-ACCESS",
        )
