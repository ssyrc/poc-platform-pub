# poc-platform v3.5.17

## UI changes

- Dashboard
  - Moved GPU Type filtering to the left Category panel under Model.
  - Added multi-select GPU Type checkboxes based on pinned dashboard data.
  - Removed the right-side Filters block so Fields → Axis/Groups → Chart flow is clearer.
  - Expanded Metrics and Dimensions field trays horizontally.
  - Made Axis/Groups drop zones visually stronger with gradient panels.

- Training / Inference
  - Removed dry-run control from the Settings & Run area.
  - Enlarged Run Training / Run Inference buttons.
  - Kept GPU Node Settings and Hyperparameters Settings panels equal-height.
  - Aligned Node Add and Detailed Parameter Edit buttons at the bottom of their panels.
  - Reworked added GPU nodes into top card-style rows with wwctl/k8s status chips.
  - Grouped Inference hyperparameters into Common / vLLM Serve or Common / Prefill / Decode sections.

- Monitoring / Results / History
  - Removed duplicate idle/status summary chips from Monitoring and Result panel headers.
  - Removed run/status/nodes/mode meta strip from Monitoring.
  - Made Result status a prominent status card with status-based color.
  - Removed status from the metrics table and renamed the first column to Result metrics.
  - Added gradient/background styling to Monitoring, Result Analysis, and Run History areas.
