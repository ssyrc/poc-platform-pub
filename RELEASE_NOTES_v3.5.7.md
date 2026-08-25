# poc-platform v3.5.7

## UI changes

- Dashboard category selector is simplified to `Training 테스트` and `Inference 테스트`.
- Training tab is reorganized into version/model, GPU node add list, hyperparameter modal, and run button.
- Training UI no longer exposes Kubernetes namespace, model path, data path, NIC binding, or CompileIQ. Scripts resolve defaults.
- Inference tab is simplified from endpoint-mode based UI to a vLLM Serve first UI.
- PD disaggregated inference is exposed as an option inside the same Inference tab with separate Prefill/Decode node add lists.
- Hyperparameters for Training and Inference are edited in modal dialogs and summarized in the main panel.

## Runtime notes

- Training still uses `scripts/training/train_k8s.sh`.
- Inference still uses `scripts/llmd/llmd_run.sh`.
- Current Training Kubernetes Job supports a single `gpus_per_node` value, so the UI blocks mixed GPU counts across Training nodes.
- Inference vLLM Serve deploy mode uses the first Serve node for pod deployment and monitors the selected nodes.
- PD mode currently uses the default llm-d service discovery path and monitors the selected Prefill/Decode hosts.
