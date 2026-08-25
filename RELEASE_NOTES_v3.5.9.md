# poc-platform v3.5.9

## 변경 사항

- OS Provisioning Warewulf API 목록 조회를 `/api/nodes/` 우선으로 변경하고 `/api/nodes` fallback을 추가했습니다.
- K8s 구성 모니터링은 기본적으로 `<control-plane-host>`에 SSH 접속 후 원격 `kubectl`을 실행합니다.
  - 기본값: `K8S_MASTER_NODE=<control-plane-host>`, `K8S_SSH_USER=root`, `K8S_USE_SSH=auto`
- Training/Inference 테스트 탭의 긴 설명 문구를 제거하고 필요한 설명은 `(i)` tooltip으로 이동했습니다.
- Add Node 및 hyperparameter 지정 버튼을 눈에 띄는 초록색 primary 버튼으로 변경했습니다.
- Inference 테스트 탭에서 MLPerf version 선택을 제거했습니다.
- Inference 테스트 탭은 `guidellm + llm-d/vLLM` 기준으로 정리했습니다.
  - model path 직접 입력
  - 기본 vLLM Serve 모드
  - PD 분산 추론 활성화 시 Prefill/Decode host를 각각 add node로 입력
  - hyperparameter modal에서 Common / Prefill / Decode 파라미터 분리
- Dashboard의 Inference 테스트 category는 `llmd_bench` / guidellm 결과를 사용합니다.
- Runtime scripts도 원격 control-plane kubectl 사용을 지원하도록 `cm_kubectl` helper를 추가했습니다.
