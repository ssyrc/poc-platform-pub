# Next Steps

- 갱신: 2026-08-28 (22회차)
- 상태: 단일 노드·2노드 학습 통과 / **멀티노드 rendezvous가 노드별로 따로 완료됨**
- **지금 할 일: 버퍼링 수정 후 다시 돌려 전 노드 출력 확보**

---

## 지금 확정된 사실

**`[LAUNCH]` 줄은 정상입니다.**

```
[.29] torchrun --nnodes=4 --node_rank=3 --nproc_per_node=8 \
      --rdzv_backend=c10d --rdzv-id=probe_28846_1787934197 \
      --rdzv_endpoint=node26:29500 --rdzv-conf=timeout=600,read_timeout=600
```

`--nnodes`, `--rdzv-id`, `--rdzv_endpoint` 모두 어긋난 곳이 없습니다.

### 그런데 로그에 `.29` 것만 나왔습니다 — 그건 제 버그였습니다

4노드 실행인데 `.26/.27/.28`은 **한 줄도** 안 나왔습니다. 그 노드들이 아무것도
안 한 게 아니라, **출력이 `sed` 버퍼에 갇혀 있었습니다.**

```bash
... | tee "${STATUS_DIR}/${i}.log" | sed "s/^/[${h}] /"     # -u 가 없었음
```

`-u` 없는 `sed`는 stdout이 터미널이 아닐 때 **4KB 블록 버퍼링**을 합니다.
`| tee nccl_probe.log`로 파이프하는 순간 그 조건이 됩니다. 여러 호스트가 동시에
돌면 **"한 노드만 출력이 있다"**로 보이고, 그건 정확히 반대되는 결론입니다.

`mlperf_run.sh`는 `sed -u`를 쓰는데 프로브만 빠져 있었습니다. 고쳤습니다.

> **주의:** 지금까지 **화면으로 본** "어느 노드가 참여했나"는 신뢰할 수 없습니다.
> 다만 `${STATUS_DIR}/*.log`(호스트별 파일)와 `PER-HOST RESULT` 표는 `tee`가 직접
> 쓴 것이라 정확합니다.

## 준비

**`git pull` 필요** (`8b4defe`).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

echo "IMG=[$IMG] TAR=[$TAR]"     # 비어 있으면 조용히 죽습니다
```

---

## STEP 1 — 전 노드 출력 확보 (지금 할 일)

**`git pull` 필요.** 이제 모든 호스트 출력이 즉시 나옵니다.

```bash
TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO \
./scripts/nccl_probe.sh --hosts node26,node27,node28,node29 \
  --image $IMG 2>&1 | tee /mgmt/server/nccl_probe.log
```

**볼 것 — 이번엔 네 호스트 모두 나와야 합니다.**

```
[node26] [REMOTE] node_rank=0 ... starting torchrun at HH:MM:SS
[node27] [REMOTE] node_rank=1 ...
[node28] [REMOTE] node_rank=2 ...
[node29] [REMOTE] node_rank=3 ...
```

시작 시각이 크게 벌어지는 노드가 있는지, 그리고 `TORCH_DISTRIBUTED_DEBUG=DETAIL`이
찍는 rendezvous 줄이 노드마다 어떻게 다른지 보시면 됩니다.

```
The node 'xxx' has joined round N of the rendezvous 'yyy' as rank R of W
Rendezvous complete for workers. Result: restart_count=... master_addr=...
```

`round`·`W`가 노드마다 다르면 거기가 답입니다.

---

## STEP 2 — 그래도 안 되면: 2노드로 좁히기

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
| `[LAUNCH]` 인자 | `--nnodes`/`--rdzv-id`/`--rdzv_endpoint` 전부 정상 확인 |

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
