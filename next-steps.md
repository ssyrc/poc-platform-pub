# Next Steps

- 갱신: 2026-08-28 (23회차)
- 상태: 단일 노드·2노드 학습 통과 / **멀티노드 rendezvous가 노드별로 따로 완료됨**
- **지금 할 일: rendezvous 내부 로그 (`TORCH_DISTRIBUTED_DEBUG` 전달 수정 후)**

---

## 지금 확정된 사실

5노드 실행 (`.26` rank0, `.27`, `.28`, `.29`, `.30`):

```
world formed: 16/40 ranks, 2/5 nodes

  rank host            exit   note
  0    node26    0      ok
  1    node27    0      ok
  2    node28    1      DistNetworkError: Failed to recv, got 0 bytes...
  3    node29    1      DistNetworkError: ...
  4    node30    1      DistNetworkError: ...
```

### 늦어서가 아닙니다 (배제)

시작 시각을 보면 **가장 늦게 시작한 노드가 성공하고, 가장 먼저 시작한 노드가 실패**합니다.

| 노드 | 시작 | 결과 |
|---|---|---|
| `.29` | 01:40:10 | **실패** (가장 이름) |
| `.30` | 01:40:19 | 실패 |
| `.28` | 01:40:41 | 실패 |
| `.27` | **01:40:50** | **성공** (가장 늦음) |

**성공한 것은 node_rank 0과 1**입니다. 시작 순서와 무관합니다.

### `[LAUNCH]` 인자도 정상

다섯 호스트 전부 `--nnodes=5`, 같은 `--rdzv-id`, 같은 `--rdzv_endpoint`입니다.

```
--nnodes=5 --node_rank=N --rdzv-id=probe_31320_1787935247 --rdzv_endpoint=node26:29500
```

`--nnodes=5`면 min=max=5라 **2노드로 완료될 수 없습니다.** 그런데 됐습니다.
여기부터는 torch 내부를 봐야 합니다.

### rendezvous 로그가 안 나온 이유 — 제 버그

`TORCH_DISTRIBUTED_DEBUG`와 `LOGLEVEL`이 **프로브의 전달 목록에 없었습니다.**
셸에 설정해도 컨테이너까지 가지 않았습니다. 로그의 `env into container` 줄에도
없습니다. 제가 전달되지 않는 변수를 알려드렸습니다. 추가했습니다.

## 준비

**`git pull` 필요** (`8b4defe`).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

echo "IMG=[$IMG] TAR=[$TAR]"     # 비어 있으면 조용히 죽습니다
```

---

## STEP 1 — rendezvous 내부 로그 (지금 할 일)

**`git pull` 필요.** 이제 `TORCH_DISTRIBUTED_DEBUG`/`LOGLEVEL`이 컨테이너까지 갑니다.

```bash
TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO \
./scripts/nccl_probe.sh --hosts node26,node27,node28 \
  --image $IMG 2>&1 | tee /mgmt/server/nccl_probe.log
```

먼저 이 줄로 **실제로 전달됐는지** 확인하세요.

```
[INFO] env into container: ... TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO
```

그다음 볼 것:

```
The node 'xxx' has joined round N of the rendezvous 'yyy' as rank R of W
Rendezvous complete for workers. Result: restart_count=... master_addr=...
```

**`W`가 몇으로 나오는지, `round` 번호가 노드마다 같은지**가 답입니다.
3노드로 좁혀서 돌리시면 로그를 끝까지 읽을 수 있습니다.

---

## STEP 2 — 그래도 안 되면: 2노드

여기까지 오면 torch가 뭘 하는지 직접 봐야 합니다.

rank 0과 문제 노드 하나만 남겨서, 로그를 끝까지 읽을 수 있게 합니다.

```bash
TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO \
./scripts/nccl_probe.sh --hosts node26,node27 --image $IMG 2>&1 | tee /tmp/rdzv.log
```

---

## 배제된 것 (다시 볼 필요 없음)

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

## 실행 참고

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
| **멀티노드 rendezvous** | **미해결.** STEP 1 진행 중 |
| SHARP 부재 | B300은 HPC-X 플러그인을 끄므로 in-network reduction 없음. 정식 측정 전 결정 필요 |
| 스케일링 측정 | 1/2/4/8 스텝 시간 비교 (미착수) |
| llama2_70b_lora | B300에서 미실행 |
| `frontend/app.jsx` | 어디서도 로드 안 되는 잔존 파일 (정리 보류) |

---

## 참고

`Errors`에 노드 IP·호스트명·사내 레지스트리 주소가 들어가 있습니다.
이 저장소는 public입니다. 원하시면 익명화해 드리겠습니다.
