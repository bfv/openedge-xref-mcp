"""MCP server exposing OpenEdge ABL XREF cross-reference information."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from threading import RLock
from typing import Any

from mcp.server.fastmcp import FastMCP

from .indexer import XrefIndex
from .models import XrefEntry
from .watcher import XrefWatcher

mcp = FastMCP("openedge-xref-mcp")

_ROOT_ENV_VAR = "OPENEDGE_XREF_ROOT"
_WATCH_ENV_VAR = "OPENEDGE_XREF_WATCH"


class _State:
    root: Path
    index: XrefIndex
    lock: RLock


_state = _State()
_state.root = Path(os.environ.get(_ROOT_ENV_VAR, ".")).resolve()
_state.index = XrefIndex.build(_state.root)
_state.lock = RLock()
_watcher: XrefWatcher | None = None


def _refresh_from_watcher() -> None:
    with _state.lock:
        _state.index.refresh()


def _start_watcher() -> None:
    global _watcher
    _watcher = XrefWatcher(_state.root, _refresh_from_watcher)
    _watcher.start()


def _stop_watcher() -> None:
    global _watcher
    if _watcher:
        _watcher.stop()
        _watcher = None


def _entry_to_dict(entry: XrefEntry) -> dict[str, Any]:
    return {
        "source_name": entry.source_name,
        "file_name": entry.file_name,
        "line_number": entry.line_number,
        "xref_type": entry.xref_type,
        "detail": entry.detail,
        "xref_file": entry.xref_file,
    }


@mcp.tool()
def set_xref_root(path: str) -> dict[str, Any]:
    """Set the root directory to scan for .xref files and rebuild the index."""
    root = Path(path).expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"Not a directory: {root}")
    was_watching = _watcher is not None
    _stop_watcher()
    with _state.lock:
        _state.root = root
        _state.index = XrefIndex.build(root)
        result = {
            "root": str(_state.root),
            "xref_files": len(_state.index.xref_files),
            "programs": len(_state.index.programs()),
        }
    if was_watching:
        _start_watcher()
    return result


@mcp.tool()
def refresh_index() -> dict[str, Any]:
    """Re-scan the current root directory, reparsing only new/changed/removed .xref files."""
    with _state.lock:
        stats = _state.index.refresh()
        return {
            "root": str(_state.root),
            "xref_files": len(_state.index.xref_files),
            "programs": len(_state.index.programs()),
            **stats,
        }


@mcp.tool()
def get_index_status() -> dict[str, Any]:
    """Return the current root directory and index size."""
    with _state.lock:
        return {
            "root": str(_state.root),
            "xref_files": len(_state.index.xref_files),
            "programs": len(_state.index.programs()),
            "entries": len(_state.index.entries),
        }


@mcp.tool()
def list_programs() -> list[str]:
    """List all source programs/classes found in the indexed .xref files."""
    with _state.lock:
        return _state.index.programs()


@mcp.tool()
def get_program_xref(program: str, xref_type: str | None = None) -> list[dict[str, Any]]:
    """Return all XREF entries recorded for a given source program or class.

    Optionally filter by xref-type (e.g. ACCESS, INVOKE, METHOD, INCLUDE).
    """
    with _state.lock:
        entries = _state.index.get_program_entries(program)
        if xref_type:
            entries = [e for e in entries if e.xref_type == xref_type.upper()]
        return [_entry_to_dict(e) for e in entries]


@mcp.tool()
def find_table_usage(table: str, field: str | None = None) -> list[dict[str, Any]]:
    """Find every program/class that references a database table (optionally a specific field)."""
    with _state.lock:
        entries = _state.index.find_table_usage(table, field)
        return [_entry_to_dict(e) for e in entries]


@mcp.tool()
def find_callers(target: str) -> list[str]:
    """List programs/classes that RUN, NEW, or INVOKE the given procedure, class, or method."""
    with _state.lock:
        return _state.index.find_callers(target)


@mcp.tool()
def find_callees(program: str) -> list[str]:
    """List procedures, classes, or methods that the given program RUNs, NEWs, or INVOKEs."""
    with _state.lock:
        return _state.index.find_callees(program)


@mcp.tool()
def list_includes(program: str) -> list[str]:
    """List include files ({...}) used by the given program or class."""
    with _state.lock:
        return _state.index.get_includes(program)


@mcp.tool()
def search_xref(query: str, xref_type: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
    """Free-text search across all XREF entries (source name and detail), case-insensitive."""
    with _state.lock:
        results = _state.index.search(query, xref_type)
        return [_entry_to_dict(e) for e in results[:limit]]


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=os.environ.get(_ROOT_ENV_VAR, "."),
        help="Directory to scan for .xref files (default: current directory)",
    )
    parser.add_argument(
        "--watch",
        action=argparse.BooleanOptionalAction,
        default=os.environ.get(_WATCH_ENV_VAR, "true").lower() != "false",
        help="Watch for .xref changes and refresh automatically (default: enabled)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)
    root = Path(args.root).expanduser().resolve()
    with _state.lock:
        _state.root = root
        _state.index = XrefIndex.build(root)
    if args.watch:
        _start_watcher()
    try:
        mcp.run()
    finally:
        _stop_watcher()


if __name__ == "__main__":
    main()
