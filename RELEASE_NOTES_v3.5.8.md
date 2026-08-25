# poc-platform v3.5.8

## 변경 사항

### 테스트 클러스터 관리 - OS Provisioning
- OS Provisioning 탭을 좌/우 2구역으로 개편했습니다.
  - 왼쪽: Warewulf 동작
  - 오른쪽: Warewulf 모니터링
- Warewulf 노드 추가 UI를 추가했습니다.
- 노드 전원 제어 UI를 추가했습니다.
  - action: `on`, `off`, `cycle`, `reset`
  - backend는 `POST /api/nodes/{hostname}/power` + body `{ "action": "..." }` 형태로 Warewulf API에 전달합니다.
- Warewulf API의 `/api/nodes` 응답을 hostname 기준으로 parsing하여 image/profile/network/ipmi/overlay 정보를 표시합니다.
- 노드 부팅 완료 확인 기능을 추가했습니다.
  - ping 성공: network up
  - SSH 성공: boot complete

### 테스트 클러스터 관리 - K8s 구성
- worker node 조인 UI를 제거했습니다.
- K8s 모니터링 주기를 5초로 조정했습니다.
- `kubectl get svc -A` 기반 서비스 모니터링을 추가했습니다.
- pod/container 상태 모니터링을 강화했습니다.
  - pod phase, ready, restart, pod IP
  - container image, state, ready, restart
- deployment/statefulset/daemonset 워크로드 모니터링을 추가했습니다.
- control-plane에서 `/etc/kubernetes/admin.conf`가 있으면 `KUBECONFIG` 기본값으로 자동 설정합니다.

## 검증

```bash
python3 -m py_compile backend/*.py
bash -n start_platform.sh scripts/*.sh scripts/*/*.sh
frontend/index.html Babel transform
```
