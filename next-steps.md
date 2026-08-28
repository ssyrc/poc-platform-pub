# Next Steps

- 갱신: 2026-08-28 (21회차)
- 상태: 단일 노드·2노드 학습 통과 / **멀티노드 rendezvous가 노드별로 따로 완료됨**
- **지금 할 일: 각 호스트가 실제로 실행한 `[LAUNCH]` 줄 확인**

---

## 지금 확정된 사실

2노드(`.28`, `.29`)로 좁힌 실행:

```
[.28] [probe r0..r7] all_reduce OK (= 8.0)          <- 8 ranks, 한 노드
      PARTICIPATING NODES: node-26052  8  0-7  <- 자기 혼자
      world formed: 8/16 ranks, 1/2 nodes

[.29] recvValueWithTimeout failed ... remote=[node-26052]:29500
      Connection was likely closed.
```

**`.28`이 `.29`를 기다리지 않고 혼자 world 8을 만들어 끝까지 돌았습니다.**
`.29`는 그 뒤에 붙었고 store는 이미 사라진 뒤였습니다.

**`init_process_group`은 실패 지점이 아닙니다.** `.28`은 `init_process_group OK`까지
정상이고, `.29`의 스택은 `_PyRun_SimpleFileObject` → `PrefixStore::get`이라
**워커가 이미 실행 중**이었습니다. 양쪽 다 rendezvous를 "완료"했는데 world가 다릅니다.

### 왜 불가능한가

```
--nnodes=2  ->  min=max=2.  2개가 모여야 완료.  1노드로는 완료 불가
```

스크립트가 생성하는 명령줄은 확인했고 정확합니다.

```
torchrun --nnodes=2 --node_rank=0 ...
torchrun --nnodes=2 --node_rank=1 ...
```

**그러니 컨테이너에 실제로 전달된 것이 이것과 다릅니다.** 그게 다음 단계입니다.

---

## 준비

**`git pull` 필요** (`8b4defe`).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

echo "IMG=[$IMG] TAR=[$TAR]"     # 비어 있으면 조용히 죽습니다
```

---

## STEP 1 — 실제 실행된 명령줄 (지금 할 일)

```bash
./scripts/nccl_probe.sh --hosts node28,node29 --image $IMG 2>&1 \
  | grep -E '\[LAUNCH\]|\[REMOTE\]'
```

두 줄이 나옵니다.

```
[node28] [LAUNCH] torchrun --nnodes=2 --node_rank=0 --rdzv-id=... --rdzv_endpoint=...
[node29] [LAUNCH] torchrun --nnodes=2 --node_rank=1 --rdzv-id=... --rdzv_endpoint=...
```

**볼 것 — 셋 중 하나라도 어긋나면 거기가 원인입니다.**

| 항목 | 정상 |
|---|---|
| `--nnodes` | 양쪽 다 `2` |
| `--rdzv-id` | 양쪽 **동일** |
| `--rdzv_endpoint` | 양쪽 **동일**, rank 0의 주소 |

제 로깅과 무관하게 독립 확인:

```bash
for h in node28 node29; do
  printf '%-16s ' "$h"; ssh $h "docker ps -a --format '{{.Command}}' | head -1"
done
```

---

## STEP 2 — 명령줄이 정상이면: rendezvous 내부 로그

여기까지 오면 torch가 뭘 하는지 직접 봐야 합니다.

```bash
TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO \
./scripts/nccl_probe.sh --hosts node28,node29 --image $IMG 2>&1 | tee /tmp/rdzv.log
```

볼 줄:

```
The node 'xxx' has joined round N of the rendezvous 'yyy' as rank R of W
Rendezvous complete for workers. Result: restart_count=... master_addr=...
```

`round`와 `rendezvous` id가 두 노드에서 같은지, `W`가 몇으로 나오는지가 답입니다.

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
| `init_process_group` | 실패 지점 아님 (위 참조) |

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
