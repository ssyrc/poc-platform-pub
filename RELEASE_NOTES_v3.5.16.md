# v3.5.16

## UI updates

- Dashboard
  - Category buttons are stacked vertically.
  - Fields area now spans the full chart control width.
  - Axis, group, filter controls are placed below the expanded Fields area.

- Training / Inference
  - Run button moved into the basic settings row next to the main selectors.
  - Configuration area reduced to two equal-height cards: GPU node settings and Hyperparameters settings.
  - GPU count stepper now displays only `- N +` without native browser spinner controls.
  - Added node chips now display host and GPU count as `gpu-node03 8GPU` style labels.
  - Hyperparameters are displayed in a compact name/value grid.
  - Inference mode switch is now at the top of GPU node settings.

- Monitoring / Results
  - Live Monitoring and Result Analysis headers now stretch across each panel.
  - Result Analysis shows status prominently above the metrics table.
  - Hyperparameter summary was removed from Result Analysis.
  - Log path copy action is shown only for successful results.
