from pathlib import Path

from openedge_xref_mcp.parser import (
    extract_call_target,
    extract_table_field,
    parse_file,
)

FIXTURE = Path(__file__).parent / "fixtures" / "OrderService.cls.xref"


def test_parse_file_line_count():
    entries = parse_file(FIXTURE)
    assert len(entries) == 9


def test_parse_basic_fields():
    entries = parse_file(FIXTURE)
    compile_entry = entries[0]
    assert compile_entry.source_name == "./src/app/service/OrderService.cls"
    assert compile_entry.line_number == 1
    assert compile_entry.xref_type == "COMPILE"
    assert compile_entry.detail == "app/service/OrderService.cls"


def test_extract_table_field():
    entries = parse_file(FIXTURE)
    access_entries = [e for e in entries if e.xref_type == "ACCESS"]
    table, field = extract_table_field(access_entries[0])
    assert table == "sports2020.Order"
    assert field == "OrderNum"


def test_extract_table_field_ignores_property_access():
    entries = parse_file(FIXTURE)
    property_entry = next(e for e in entries if "PUBLIC-PROPERTY" in e.detail)
    table, field = extract_table_field(property_entry)
    assert table is None
    assert field is None


def test_extract_call_target():
    entries = parse_file(FIXTURE)
    new_entry = next(e for e in entries if e.xref_type == "NEW")
    assert extract_call_target(new_entry) == "fwebh.pas.data.ResponseData"

    invoke_entry = next(e for e in entries if e.xref_type == "INVOKE")
    assert extract_call_target(invoke_entry) == "app.service.OrderService:OrderToJson"


def test_include_detected():
    entries = parse_file(FIXTURE)
    include_entry = next(e for e in entries if e.xref_type == "INCLUDE")
    assert include_entry.is_include
    assert include_entry.detail == "app/service/common.i"
