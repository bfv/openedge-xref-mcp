from pathlib import Path

from openedge_xref_mcp.indexer import XrefIndex

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
