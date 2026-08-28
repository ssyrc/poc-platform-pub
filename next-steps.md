# Next Steps

- 갱신: 2026-08-28 (24회차)
- 상태: 단일 노드·2노드 학습 통과 / 멀티노드 rendezvous는 **다른 분께 인계**
- **지금 할 일: 플랫폼 기동 후 UI 로 end-to-end 테스트** → [docs/start-platform.md](docs/start-platform.md)

---

## 지금 할 일 — 플랫폼 띄우고 테스트

가이드를 `docs/start-platform.md` 에 정리했습니다. 요약하면 이 순서입니다.

### 1. `.env`

```bash
cd /opt/poc-platform/poc-platform-latest
cp .env.example .env
```

**H B300 을 쓸 거면 이 두 줄이 필수입니다.** S(`platform`)에서 `node*` 로
직접 가는 경로가 없습니다.

```bash
MLPERF_NET_H_HPC_JUMP=root@bastion1,root@bastion2
MLPERF_NET_H_HPC_SSH_OPTS=-o ConnectTimeout=20
```

먼저 손으로 뚫리는지 확인 — 여기서 막히면 UI 도 똑같이 막힙니다.

```bash
ssh -J root@bastion1,root@bastion2 root@node26 hostname
```

### 2. 기동

```bash
systemctl restart poc-platform.service        # 운영 8100
# 또는 손으로
SKIP_PIP_INSTALL=1 PORT=8101 ./start_platform.sh
```

`start_platform.sh` 의 기본 포트는 **8089** 입니다. 8100/8101 은 systemd 가 `PORT` 를
넣어 주는 값이라, 손으로 띄울 때는 직접 줘야 합니다.

### 3. 확인

```bash
curl -s localhost:8100/api/health
curl -s localhost:8100/api/config | python3 -m json.tool | head -40   # scripts_dir / data_root / state_dir
./scripts/preflight.sh training v5.1
```

### 4. 브라우저

```bash
ssh -J <로그인노드> -L 8100:localhost:8100 root@platform
```

→ `http://localhost:8100`

### 5. UI 테스트 순서

1. `network` 버튼 → **H HPC센터** (B300 쓸 때)
2. `hosts` 입력 → GPU 타입이 `B300` 으로 잡히면 **ssh 경로가 실제로 뚫린 것**
3. **dry-run** 으로 한 번 → `--nnodes`, `MASTER_ADDR`, 유도된 GBS, 이미지 이름 확인
4. 실제 run: **1노드 → 2노드** 순서로. `--gbs` 는 비워 두세요(노드 수에서 파생)
5. 결과: Recent Runs / `/api/runs/<id>/report`

---

## 인계 — 멀티노드 rendezvous (미해결)

5노드 실행에서 **선언한 것보다 작은 world 가 형성**됩니다.

```
world formed: 16/40 ranks, 2/5 nodes

  rank host            exit   note
  0    node26    0      ok
  1    node27    0      ok
  2    node28    1      DistNetworkError: Failed to recv, got 0 bytes
  3    node29    1      DistNetworkError: ...
  4    node30    1      DistNetworkError: ...
```

다섯 호스트 전부 `[LAUNCH]` 인자가 동일합니다.

```
--nnodes=5 --node_rank=N --rdzv-id=probe_31320_1787935247 --rdzv_endpoint=node26:29500
```

`--nnodes=5`면 min=max=5라 **2노드로 완료될 수 없습니다.** 그런데 됐습니다.
성공한 것은 node_rank 0·1이고, 시작 순서와는 무관합니다(가장 늦게 시작한 노드가 성공).

### 이어서 볼 것

`TORCH_DISTRIBUTED_DEBUG`/`LOGLEVEL`이 프로브의 전달 목록에 없어 컨테이너까지 가지 않았습니다.
`fadcb2a` 에서 고쳤으므로 이제 rendezvous 내부 로그를 받을 수 있습니다.

```bash
TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO \
./scripts/nccl_probe.sh --hosts node26,node27,node28 --image $IMG 2>&1 | tee /tmp/rdzv.log
```

전달됐는지 먼저 확인: `[INFO] env into container: ... TORCH_DISTRIBUTED_DEBUG=DETAIL`

그다음 이 두 줄에서 **`W`가 몇인지, `round` 번호가 노드마다 같은지**가 답입니다.

```
The node 'xxx' has joined round N of the rendezvous 'yyy' as rank R of W
Rendezvous complete for workers. Result: restart_count=... master_addr=...
```

### 배제된 것 (다시 볼 필요 없음)

| 가설 | 근거 |
|---|---|
| 네트워크 도달 불가 | 도달성 검사 통과. 소켓 실제로 열림 |
| GPU 수 불일치 | 전 호스트 8개 확인 |
| 이미지 없음 | 전 노드 사전 로드 후 대기 |
| 드라이버·OFED·ACS·peermem 차이 | `node_diff` 25~26개 항목 일치 |
| 시계 skew | **정상 노드도 65s.** 검사는 경고로 완화 |
| `read_timeout` 60s | 고침(`fdaa5c6`). 그래도 재현 |
| 잔존 컨테이너 겹침 | `docker ps` 비어 있음 |
| `init_process_group` | 실패 지점 아님 |
| `[LAUNCH]` 인자 | 5호스트 전부 `--nnodes=5`, 같은 id·endpoint |
| 시작 시각 차이 | 가장 늦게 시작한 노드가 성공. 무관 |

---

## 이미 해결된 원인

| 증상 | 원인 | 커밋 |
|---|---|---|
| `Unsupported precision bf16-mixed` | 8b `pretrain.py`는 `bf16`만 받음 | `d4a11f3` |
| SIGSEGV (`ncclCommInitRankConfig`) | HPC-X `libnccl-net.so` ↔ NCCL 2.28.3 불일치 | `489dc11` |
| IB `status=4` | PCIe ACS가 NIC↔GPU P2P DMA 차단 | ACS 해제 (완료) |
| `npy_index` FileNotFound | 노드마다 다른 캐시 경로 | `5cbdc5b` |
| 조용한 exit 1 | `$IMG` 미설정 → 값 없는 플래그 → `shift 2` 실패 | `521b198` |
| 60초 join 절단 | `read_timeout`(기본 60s)을 안 건드렸음 | `fdaa5c6` |
| step 로그가 `run.log`에 안 남음 | 컨테이너 출력을 tee 하지 않았음 | `42cc79f` |

---

## 도구

| 스크립트 | 용도 |
|---|---|
| `nccl_probe.sh --hosts-file F --image I` | NCCL만 30초 검증 + 참여/대역폭/실패사유 표 |
| `node_diff.sh --hosts-file F` | 노드끼리 비교 — **다른 것만** |
| `node_check.sh --host H --image I` | 노드 하나의 전제조건 |
| `acs_check.sh --host H` | PCIe ACS 상태 (읽기 전용) |
| `preflight.sh` | 관리 서버 쪽 |
| `run_multi_node.sh` / `run_single_node.sh` | 실행 |

프로브가 마지막에 내는 것: `PARTICIPATING NODES` / `ALL-REDUCE BANDWIDTH`(busbw가
world size 간 비교 가능) / `PER-HOST RESULT`(exit + 실패 사유) / `world formed: N/M`.

---

## 실행 참고 (CLI)

`--gbs`는 **생략하세요.** 노드 수에서 파생됩니다(`MBS x DP x grad_accum`, 기본 128).
1/2/4/8노드가 128/256/512/1024가 되어 GPU당 일이 일정하게 유지됩니다.

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_multi_node.sh --hosts-file hostfile \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --cp 1 --mbs 1 --max-steps 10
```

로그는 노드마다 `${LOG_DIR}/container.log`(학습 출력 전량)와 `run.log`에 남습니다.

---

## 남은 이슈

| 항목 | 상태 |
|---|---|
| 플랫폼 end-to-end 테스트 | **진행 중** (`docs/start-platform.md`) |
| 멀티노드 rendezvous | 미해결. **다른 분께 인계** |
| SHARP 부재 | B300은 HPC-X 플러그인을 끄므로 in-network reduction 없음. 정식 측정 전 결정 필요 |
| 스케일링 측정 | 1/2/4/8 스텝 시간 비교 (미착수) |
| llama2_70b_lora | B300에서 미실행 |
| `frontend/app.jsx` | 어디서도 로드 안 되는 잔존 파일 (정리 보류) |

---

## 참고

`Errors`에 노드 IP·호스트명·사내 레지스트리 주소가 들어가 있습니다.
이 저장소는 public입니다. 원하시면 익명화해 드리겠습니다.
