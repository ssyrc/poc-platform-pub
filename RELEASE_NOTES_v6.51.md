# v6.51

- Dashboard legend labels are now compact value-only labels, e.g. `A100 / v4.1 / Llama2_70b_lora / Bare Metal`.
- Dashboard auto grouping now adds version/model/environment only when the corresponding filter is `all` and multiple distinct values are present in the currently graphed pinned data.
- Fixed vLLM single-instance `--group 0` by avoiding Bash's special `GROUPS` variable.
- Mounted the host Docker CLI and Docker socket into MLPerf Inference v5.1/v6.0 containers so NVIDIA Makefile.docker can invoke `docker` from inside the container.
- PD Disaggregation no longer requires Prefill and Decode nodes to be different hosts.
- PD CUDA_VISIBLE_DEVICES inputs no longer lose focus after each typed character.
