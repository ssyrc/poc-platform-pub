# v6.52

- Dashboard numeric X axis tick handling updated for sparse numeric x values.
- Dashboard legend labels now show value-only labels for auto-scoped series.
- MLPerf Inference container-side docker calls rewrite nvcr.io image references to ${NVCR_PULL_PREFIX}.
- vLLM health polling no longer exits immediately on curl connection-refused while the server is still starting.
- vLLM serve crash diagnostics now dump recent container logs before cleanup.
- vLLM Single Instance CUDA_VISIBLE_DEVICES input no longer remounts on every keystroke.
- vLLM GPU node count changes update derived TP and PD instance defaults.
