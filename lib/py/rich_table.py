#!/usr/bin/env python3
"""
Render TSV rows as a terminal table.

Usage:
  cat rows.tsv | rich_table.py --columns "A,B,C" --widths "20,10,0" --title "My Table"

Requires `rich`.
"""

from __future__ import annotations

import argparse
import sys
from typing import List


def _split_csv(value: str) -> List[str]:
    return [part.strip() for part in value.split(",")]


def _parse_widths(widths_csv: str, count: int) -> List[int]:
    raw = _split_csv(widths_csv)
    if len(raw) != count:
        raise ValueError("width count must match columns count")
    widths: List[int] = []
    for item in raw:
        n = int(item)
        widths.append(n if n > 0 else 0)
    return widths


def _parse_aligns(align_csv: str, count: int) -> List[str]:
    raw = _split_csv(align_csv)
    if len(raw) != count:
        raise ValueError("align count must match columns count")
    aligns: List[str] = []
    for item in raw:
        v = item.lower()
        if v not in {"left", "center", "right"}:
            raise ValueError("align values must be left/center/right")
        aligns.append(v)
    return aligns


def _read_rows(expected_cols: int) -> List[List[str]]:
    rows: List[List[str]] = []
    for line in sys.stdin.read().splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < expected_cols:
            parts.extend([""] * (expected_cols - len(parts)))
        elif len(parts) > expected_cols:
            parts = parts[: expected_cols - 1] + [" ".join(parts[expected_cols - 1 :])]
        rows.append(parts)
    return rows


def _render_rich(title: str, columns: List[str], widths: List[int], aligns: List[str], rows: List[List[str]]) -> None:
    from rich import box
    from rich.console import Console
    from rich.text import Text
    from rich.table import Table

    table = Table(
        title=title or None,
        show_header=True,
        header_style="bold grey70",
        box=box.SIMPLE_HEAVY,
        border_style="grey50",
        expand=False,
        show_lines=False,
        row_styles=("", "dim"),
    )
    for idx, col in enumerate(columns):
        max_width = widths[idx] if widths[idx] > 0 else None
        table.add_column(
            Text.from_markup(col),
            justify=aligns[idx],
            overflow="fold",
            no_wrap=False,
            max_width=max_width,
        )
    for row in rows:
        if row and row[0] == "__SECTION__":
            table.add_section()
            continue
        table.add_row(*(Text.from_markup(cell) for cell in row))
    console = Console(highlight=False, soft_wrap=False, markup=True)
    console.print(table)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render TSV input as a terminal table.")
    parser.add_argument("--columns", required=True, help="Comma-separated column names.")
    parser.add_argument("--widths", default="", help="Comma-separated max widths (0 = auto).")
    parser.add_argument("--align", default="", help="Comma-separated align values: left|center|right.")
    parser.add_argument("--title", default="", help="Table title.")
    args = parser.parse_args()

    columns = _split_csv(args.columns)
    if not columns or any(not c for c in columns):
        raise SystemExit("invalid columns")

    if args.widths:
        widths = _parse_widths(args.widths, len(columns))
    else:
        widths = [0] * len(columns)

    if args.align:
        aligns = _parse_aligns(args.align, len(columns))
    else:
        aligns = ["left"] * len(columns)

    rows = _read_rows(len(columns))

    _render_rich(args.title, columns, widths, aligns, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
