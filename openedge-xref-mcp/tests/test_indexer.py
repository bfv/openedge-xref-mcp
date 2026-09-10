import os
from pathlib import Path
from threading import Event

from openedge_xref_mcp.indexer import XrefIndex
from openedge_xref_mcp.watcher import XrefWatcher

FIXTURES_DIR = Path(__file__).parent / "fixtures"


def test_build_index_from_directory():
    index = XrefIndex.build(FIXTURES_DIR)
    assert len(index.xref_files) == 1
    assert "./src/app/service/OrderService.cls" in index.programs()


def test_find_table_usage():
    index = XrefIndex.build(FIXTURES_DIR)
    usages = index.find_table_usage("sports2020.Order")
    assert len(usages) == 3  # ACCESS OrderNum, SEARCH OrderNum, ACCESS CustNum

    field_usages = index.find_table_usage("sports2020.Order", "CustNum")
    assert len(field_usages) == 1


def test_find_table_usage_without_database_qualifier():
    index = XrefIndex.build(FIXTURES_DIR)

    usages = index.find_table_usage("Order")

    assert len(usages) == 3


def test_calls_and_callers():
    index = XrefIndex.build(FIXTURES_DIR)
    callees = index.find_callees("./src/app/service/OrderService.cls")
    assert "fwebh.pas.data.ResponseData" in callees
    assert "app.service.OrderService:OrderToJson" in callees

    callers = index.find_callers("fwebh.pas.data.ResponseData")
    assert "./src/app/service/OrderService.cls" in callers


def test_includes():
    index = XrefIndex.build(FIXTURES_DIR)
    includes = index.get_includes("./src/app/service/OrderService.cls")
    assert includes == ["app/service/common.i"]


def test_search():
    index = XrefIndex.build(FIXTURES_DIR)
    results = index.search("OrderNum")
    assert len(results) >= 2


def _write(path: Path, source_name: str, line: str) -> None:
    path.write_text(
        f"{source_name} {source_name} 1 COMPILE {source_name}\n"
        f"{source_name} {source_name} {line}\n"
    )


def test_refresh_reparses_only_changed_files(tmp_path: Path):
    file_a = tmp_path / "a.xref"
    file_b = tmp_path / "b.xref"
    _write(file_a, "./a.p", "10 ACCESS sports2020.Order OrderNum")
    _write(file_b, "./b.p", "10 ACCESS sports2020.Customer Name")

    index = XrefIndex.build(tmp_path)
    assert index.programs() == ["./a.p", "./b.p"]
    assert len(index.find_table_usage("sports2020.Order")) == 1

    stats = index.refresh()
    assert stats == {"added": 0, "changed": 0, "removed": 0, "unchanged": 2}

    # touch only file_a with a new mtime and different content
    _write(file_a, "./a.p", "11 ACCESS sports2020.Order CustNum")
    new_mtime = file_a.stat().st_mtime + 5
    os.utime(file_a, (new_mtime, new_mtime))

    stats = index.refresh()
    assert stats == {"added": 0, "changed": 1, "removed": 0, "unchanged": 1}
    assert len(index.find_table_usage("sports2020.Order", "CustNum")) == 1
    assert len(index.find_table_usage("sports2020.Order", "OrderNum")) == 0
    # untouched file's data survives
    assert len(index.find_table_usage("sports2020.Customer")) == 1


def test_refresh_removes_deleted_files(tmp_path: Path):
    file_a = tmp_path / "a.xref"
    _write(file_a, "./a.p", "10 ACCESS sports2020.Order OrderNum")

    index = XrefIndex.build(tmp_path)
    assert "./a.p" in index.programs()

    file_a.unlink()
    stats = index.refresh()
    assert stats == {"added": 0, "changed": 0, "removed": 1, "unchanged": 0}
    assert index.programs() == []
    assert index.find_table_usage("sports2020.Order") == []


def test_refresh_adds_new_files(tmp_path: Path):
    index = XrefIndex.build(tmp_path)
    assert index.programs() == []

    file_a = tmp_path / "a.xref"
    _write(file_a, "./a.p", "10 ACCESS sports2020.Order OrderNum")
    stats = index.refresh()
    assert stats == {"added": 1, "changed": 0, "removed": 0, "unchanged": 0}
    assert index.programs() == ["./a.p"]


def test_watcher_refreshes_index_after_xref_file_is_written(tmp_path: Path):
    index = XrefIndex.build(tmp_path)
    refreshed = Event()

    def refresh() -> None:
        index.refresh()
        refreshed.set()

    watcher = XrefWatcher(tmp_path, refresh, debounce_seconds=0.01)
    watcher.start()
    try:
        _write(tmp_path / "saved.xref", "./saved.p", "10 ACCESS sports2020.Order OrderNum")
        assert refreshed.wait(timeout=2)
    finally:
        watcher.stop()

    assert index.programs() == ["./saved.p"]
    assert len(index.find_table_usage("sports2020.Order", "OrderNum")) == 1
