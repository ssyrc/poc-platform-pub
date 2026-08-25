# poc-platform v3.5.25

## UI
- Dashboard GPU Type filter defaults to all selected GPUs while still allowing zero selection.
- Cluster management Warewulf monitoring table layout was tightened.
- Node SSH state is shown as connected/disconnected next to hostname.
- Warewulf node detail view renders parsed tables instead of raw JSON.
- Training test has an MLPerf sub-tab.
- Inference test has MLPerf and vLLM sub-tabs.
- Common runtime environment selector added: K8s / Bare Metal.
- GPU node cards hide wwf/k8s status in Bare Metal mode and show it in K8s mode.
- Inference vLLM Single Instance label replaces the old Inference test wording.
- Hyperparameter numeric fields use `- number +` controls without browser spinner buttons.

## Runtime
- Training MLPerf K8s mode continues to use `scripts/training/train_k8s.sh`.
- Training MLPerf Bare Metal mode uses the existing MLPerf launcher.
- Inference MLPerf tab uses existing MLPerf inference v5.1/v6.0 scripts.
- Inference vLLM tab uses K8s llm-d mode or Bare Metal vLLM/PD scripts based on environment selection.
