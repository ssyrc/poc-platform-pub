# poc-platform v3.5.10

## 변경 사항

- Warewulf API 401 진단을 위해 Bearer token, Basic auth, raw Authorization header를 지원합니다.
- Warewulf 노드 조회 실패 시 status, URL, 인증 설정 여부를 UI에 표시합니다.
- K8s 모니터링과 Kubernetes 실행 스크립트가 기본적으로 `<control-plane-host>`에 SSH 접속해 원격 `kubectl`을 실행하도록 보강했습니다.
- 원격 kubectl 검색 경로에 `/usr/bin/kubectl`, `/usr/local/bin/kubectl`, `/usr/sbin/kubectl` fallback을 추가했습니다.
- Training / Inference 탭의 실험 세팅, Run History, Monitoring 영역을 더 명확히 구분했습니다.
- Training / Inference 탭의 Add node UI와 Hyperparameters modal 버튼 배치를 개선했습니다.
- Training / Inference 실행 실패 시 전역 launcher 오류를 host별 Result Analysis에 표시하도록 수정했습니다.
- Training / Inference 로그 경로가 early failure 상황에서도 가능한 한 먼저 표시되도록 수정했습니다.

## 주요 환경변수

```bash
# Warewulf API
WW_API_BASE=http://<management-endpoint>:8897
WW_API_TOKEN=...
WW_AUTH_HEADER='Bearer ...'
WW_BASIC_USER=...
WW_BASIC_PASSWORD=...

# Kubernetes remote monitoring/execution
K8S_MASTER_NODE=<control-plane-host>
K8S_SSH_USER=root
K8S_USE_SSH=auto
K8S_KUBECONFIG=/etc/kubernetes/admin.conf
KUBECTL_BIN=kubectl
```
