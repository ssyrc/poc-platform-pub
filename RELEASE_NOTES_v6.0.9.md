# poc-platform v6.0.9

- Platform branding changed to Server PoC Platform.
- Test result panel renamed from 결과 분석 to 결과 확인.
- Dashboard action moved from 로그 확인 to 결과 확인 and enabled only for successful results.
- 결과 확인 and Run History panels are displayed side by side.
- LOG PATH wording and log action layout updated.
- Training MLPerf hyperparameter display uses MAX_STEPS, VAL_CHECK_INTERVAL, LIMIT_VAL_BATCHES and includes a clear-to-default action.
- Hyperparameter modals now provide a clear button to restore defaults.
- Kubernetes 관리 tab now focuses on cluster nodes and node-by-node pod/process status; service/workload aggregate panels removed.
- Test status dot handling was hardened so completed success/failure states are visible until acknowledged.
