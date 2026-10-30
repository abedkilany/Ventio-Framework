#!/usr/bin/env python3
"""Validate the manually maintained Wave 1 progress dashboard invariants."""

from datetime import datetime
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
import re
import sys


class DashboardParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables = []
        self._table = None
        self._row = None
        self._cell = None
        self.external_assets = []
        self.scripts = 0

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "script":
            self.scripts += 1
        if tag == "table":
            self._table = []
            self.tables.append(self._table)
        elif self._table is not None and tag == "tr":
            self._row = []
        elif self._row is not None and tag in {"td", "th"}:
            self._cell = []
        if tag in {"script", "img", "iframe", "link"}:
            for name in ("src", "href"):
                value = attributes.get(name, "")
                if value.startswith(("https://", "http://", "//")):
                    self.external_assets.append(value)

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag):
        if tag in {"td", "th"} and self._cell is not None and self._row is not None:
            self._row.append("".join(self._cell).strip())
            self._cell = None
        elif tag == "tr" and self._row is not None and self._table is not None:
            self._table.append(self._row)
            self._row = None
        elif tag == "table":
            self._table = None


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    path = (
        Path(__file__).resolve().parents[2]
        / "docs/progress/wave1-host-client-progress.html"
    )
    source = path.read_text(encoding="utf-8")
    parser = DashboardParser()
    parser.feed(source)
    require(parser.scripts == 0, "The dashboard must not require JavaScript.")
    require(not parser.external_assets, "The dashboard references an external asset.")
    require(
        not re.search(r"@import|url\(\s*(?:https?:)?//", source, re.IGNORECASE),
        "The dashboard stylesheet references an external resource.",
    )
    require(len(parser.tables) >= 2, "Stage status and milestone history tables are required.")

    stage_rows = []
    for row in parser.tables[0][1:]:
        if len(row) < 5:
            continue
        match = re.match(r"^(\d+)\s+—", row[0])
        if match:
            stage_rows.append((int(match.group(1)), row))
    require(
        [number for number, _ in stage_rows] == list(range(11)),
        "Expected stages 0–10 exactly once.",
    )
    weights = [
        int(re.fullmatch(r"(\d+)%", row[1]).group(1)) for _, row in stage_rows
    ]
    accepted = [
        int(re.fullmatch(r"(\d+)%", row[3]).group(1)) for _, row in stage_rows
    ]
    require(sum(weights) == 100, f"Stage weights total {sum(weights)}%, not 100%.")
    status_translation = {
        "مكتمل (PASS)": "PASS",
        "فشل التحقق (FAIL)": "FAIL",
        "متوقف بسبب عائق (BLOCKED)": "BLOCKED",
        "قيد التنفيذ (IN PROGRESS)": "IN PROGRESS",
    }
    for (_, row), weight, accepted_weight in zip(stage_rows, weights, accepted):
        require(row[2] in status_translation, f"Unknown stage status: {row[2]}")
        english_status = status_translation[row[2]]
        require(
            accepted_weight == (weight if english_status == "PASS" else 0),
            f"Stage {row[0]} accepted weight does not match its status.",
        )

    status_counts = Counter(status_translation[row[2]] for _, row in stage_rows)
    arabic_status = {
        "PASS": "مكتمل (PASS)",
        "FAIL": "فشل التحقق (FAIL)",
        "BLOCKED": "متوقف بسبب عائق (BLOCKED)",
        "IN PROGRESS": "قيد التنفيذ (IN PROGRESS)",
        "NOT STARTED": "لم يبدأ (NOT STARTED)",
    }
    expected_status = " · ".join(
        f"{status_counts[status]} {arabic_status[status]}"
        for status in ("PASS", "FAIL", "BLOCKED", "IN PROGRESS", "NOT STARTED")
        if status_counts.get(status, 0)
    )
    require(expected_status in source, "Summary stage counts do not match the table.")
    english_status_summary = "; ".join(
        f"{status_counts[status]} {status}"
        for status in ("PASS", "FAIL", "BLOCKED", "IN PROGRESS", "NOT STARTED")
        if status_counts.get(status, 0)
    )
    metric = re.search(r'<span class="metric">(\d+)%</span>', source)
    require(
        metric is not None and int(metric.group(1)) == sum(accepted),
        "Overall completion does not match accepted weights.",
    )
    require(re.search(r"<time datetime=\"([^\"]+)\">", source), "Last-update timestamp is required.")
    timestamp = re.search(r"<time datetime=\"([^\"]+)\">", source).group(1)
    datetime.fromisoformat(timestamp)
    required_sections = (
        "الأعمال المنجزة", "المتطلبات المتبقية", "الاختبارات والتحققات التي تحتاج إلى متابعة",
        "العوائق الحالية", "المخاطر النشطة", "أحدث تحقق", "مراجع Git",
        "بوابة القبول النهائي", "الخطوة القادمة:", "لا يتم تحديثها تلقائياً",
    )
    for label in required_sections:
        require(label in source, f"Missing required dashboard field: {label}")
    require(
        '<html lang="ar" dir="rtl">' in source
        and "../wave1/implementation-plan.md" in source,
        "English content and local plan link are required.",
    )
    print(f"PASS: {path}")
    print(f"PASS: {len(stage_rows)} stages, {sum(weights)}% weighted total, {sum(accepted)}% accepted, status counts {english_status_summary}.")
    print("PASS: no scripts/external assets; required progress and acceptance fields are present.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
