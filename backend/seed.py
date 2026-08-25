"""Seed documents for the dashboard analysis tabs.

These are structure-only defaults used the first time a deployment opens the
"가속기별 성능" / "비용 분석" tabs, before anything has been saved to
``POC_PLATFORM_STATE_DIR``. Numeric cells are intentionally left empty: the
real figures come from the site's own spec sheet and cost sheet, pasted in
through each tab's Excel paste mode. Shipping placeholder numbers here would
put invented values into a cost analysis, so only the row/column skeleton is
provided.
"""

from typing import Any, Dict

# --- 가속기별 성능 -----------------------------------------------------------

# Column ids the AcceleratorPerfTab renders. `hbm` columns only appear when
# "HBM 상세 정보" is toggled on.
ACCELERATOR_PERF_COLUMNS = [
    {"id": "vendor", "label": "Vendor", "kind": "text", "width": 92},
    {"id": "model", "label": "Model", "kind": "text", "width": 132},
    {"id": "release_year", "label": "출시연도", "kind": "number", "width": 88},
    {"id": "fp64", "label": "FP64", "kind": "number", "width": 82},
    {"id": "fp32", "label": "FP32", "kind": "number", "width": 82},
    {"id": "fp16", "label": "FP16", "kind": "number", "width": 82},
    {"id": "fp8", "label": "FP8", "kind": "number", "width": 82},
    {"id": "fp4", "label": "FP4", "kind": "number", "width": 82},
    {"id": "memory_gb", "label": "메모리(GB)", "kind": "number", "width": 96},
    {"id": "bandwidth_tbs", "label": "대역폭(TB/s)", "kind": "number", "width": 104},
    {"id": "process", "label": "공정", "kind": "text", "width": 88, "hbm": True},
    {"id": "die_count", "label": "# Die", "kind": "number", "width": 74, "hbm": True},
    {"id": "hbm_stacks", "label": "HBM Stacks", "kind": "number", "width": 104, "hbm": True},
]


def _perf_row(vendor: str, model: str, year: Any) -> Dict[str, Any]:
    row = {c["id"]: None for c in ACCELERATOR_PERF_COLUMNS}
    row.update({"vendor": vendor, "model": model, "release_year": year})
    return row


# Model names and release years only — every performance cell starts empty.
ACCELERATOR_PERF_ROWS = [
    _perf_row("NVIDIA", "V100", 2017),
    _perf_row("NVIDIA", "A100", 2020),
    _perf_row("NVIDIA", "H100", 2022),
    _perf_row("NVIDIA", "H200", 2024),
    _perf_row("NVIDIA", "B200", 2024),
    _perf_row("NVIDIA", "B300", 2025),
    _perf_row("NVIDIA", "Rubin", 2026),
    _perf_row("NVIDIA", "Rubin Ultra", 2027),
]

DEFAULT_ACCELERATOR_PERF: Dict[str, Any] = {
    "columns": ACCELERATOR_PERF_COLUMNS,
    "rows": ACCELERATOR_PERF_ROWS,
    "row_order": [r["model"] for r in ACCELERATOR_PERF_ROWS],
    "versions": [],
    "history": [],
}


# --- 비용 분석 (GPU 모델별 TCO) ----------------------------------------------

# (label, indent, highlight, label_color)
#   indent drives the ├/└ tree characters; label_color marks the CAPEX/OPEX
#   group rows, which render as emphasised rows alongside the TCO row.
_TCO_SKELETON = [
    ("TCO", 0, True, None),
    ("감가비(직투)", 0, False, "#FFB86C"),
    ("서버", 1, False, None),
    ("네트워크", 1, False, None),
    ("Infiniband", 2, False, None),
    ("Ethernet", 2, False, None),
    ("케이블 포설", 2, False, None),
    ("운영서버", 1, False, None),
    ("스토리지", 1, False, None),
    ("운영비", 0, False, "#8BE9FD"),
    ("유지보수", 1, False, None),
    ("전기료", 1, False, None),
    ("상면비", 1, False, None),
]

# Label -> indent map. Excel copies carry no leading whitespace (indentation is
# a cell format, not text), so pasted rows are re-indented from this table.
KNOWN_ROW_INDENT = {label: indent for label, indent, _h, _c in _TCO_SKELETON}

# Rows that are the sum of their children and are never edited directly.
TCO_AGGREGATE_LABELS = ["TCO", "감가비(직투)", "네트워크", "운영비"]

DEFAULT_GPU_TCO_TABLE: Dict[str, Any] = {
    "columns": [],
    "rows": [
        {
            "label": label,
            "indent": indent,
            "highlight": highlight,
            "label_color": color,
            "values": {},
        }
        for label, indent, highlight, color in _TCO_SKELETON
    ],
    "tps_assignments": {},
    "fx_rate": 1400,
}
