# Next Steps

- 갱신: 2026-08-28 (20회차)
- 상태: **2노드 학습 완주.** 8노드에서 `node27/29/30`이 all-reduce에 합류 못 함
- 지금 할 일: rendezvous 격리(잔존 리스너 / 고유 id) 확인

---

## 1. 지금까지

| 단계 | 상태 |
|---|---|
| 단일 노드 학습 8장 | **통과** |
| 2노드 학습 (TP=8 PP=2) | **통과 — 완주** |
| 8노드 | `.27/.29/.30` 미합류 → world 56/64 |

### 해결된 원인

| 증상 | 원인 | 커밋 |
|---|---|---|
| `Unsupported precision bf16-mixed` | 8b `pretrain.py`는 `bf16`만 받음 | `d4a11f3` |
| SIGSEGV (`ncclCommInitRankConfig`) | HPC-X `libnccl-net.so` ↔ NCCL 2.28.3 불일치 | `489dc11` |
| IB `status=4` | **PCIe ACS**가 NIC↔GPU P2P DMA 차단 | ACS 해제 (완료) |
| `npy_index` FileNotFound | 노드마다 다른 캐시 경로 | `5cbdc5b` |
| 조용한 exit 1 | `$IMG` 미설정 → 값 없는 플래그 → `shift 2` 실패 | `521b198` |
| **60초 만에 끊기는 join** | **`read_timeout` (기본 60s)을 안 건드렸음** | **`fdaa5c6`** |

---

## 2. 마지막 발견 — 타임아웃이 두 개였습니다

```
waitForInput: socket ... remote=[rank0]:29500 timed out after 60000ms
```

`--rdzv-conf=timeout=600`을 줬는데도 **60초**에 끊겼습니다. c10d에는 손잡이가 둘입니다.

| 키 | 하는 일 | 기본값 |
|---|---|---|
| `timeout` | rendezvous barrier 대기 | 제가 600으로 올린 것 |
| **`read_timeout`** | **store 소켓의 각 read** | **60초, 독립적** |

barrier를 넓혀도 store read가 60초에 잘리면 소용없습니다. **소켓은 먼저 열리고**(도달성 검사 통과와 일치) 그다음 끊긴 이유입니다.

`fdaa5c6`에서 둘 다 설정합니다. **학습 런처에는 애초에 둘 다 없어서** 기본 60초로 돌고 있었고 바꿀 방법도 없었습니다 — v5.1/v4.1 모두 추가, `MLPERF_RDZV_TIMEOUT`으로 조절.

---

## 준비

**`git pull` 필요** (`ec007e8`).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

echo "IMG=[$IMG] TAR=[$TAR]"     # 비어 있으면 조용히 죽습니다. 먼저 확인
```

---

## 3. 시계는 원인이 아닙니다 (배제됨)

`node_diff` 결과에서 의미 있는 차이는 **시계 하나**였습니다 (클러스터1 117s, 클러스터2 31s).
`docker_root_free`는 디스크 사용량이라 무의미합니다.

**하지만 all-reduce가 정상인 노드들에서도 65s skew가 나옵니다.** 그러니 원인이 아닙니다.
검사는 **경고만** 하도록 되돌렸습니다 — 차단으로 두면 지금 도는 구성을 막게 됩니다.

(고칠 가치는 있습니다. rendezvous heartbeat가 각 노드의 벽시계로 찍히고 남의 시계로
판정되므로 기여 요인은 될 수 있습니다. 다만 **단독 원인은 아님이 실측으로 확인됐습니다.**)

---

## 4. 지금까지 배제된 것

| 가설 | 근거 |
|---|---|
| 네트워크 도달 불가 | 도달성 검사 전부 통과. 소켓도 실제로 열림 |
| GPU 수 불일치 | 전 호스트 8개 확인 |
| 이미지 없음 | 사전 로드 후 대기, 전 노드 ready |
| 드라이버/OFED/ACS/peermem 차이 | `node_diff` 25~26개 항목 일치 |
| **시계 skew** | **정상 노드도 65s** |
| `read_timeout` 60s | 고침(`fdaa5c6`). 그래도 재현 |

---

## 5. 산수가 맞지 않았습니다 — 라운드가 두 개였습니다

`init_process_group`은 문제가 아닙니다. 거기까지 가지도 못합니다.

```
1. torchrun 에이전트가 rendezvous 완료      <- 실패 지점
2. 워커(python) 시작
3. 워커가 init_process_group 호출            <- [probe rN] 로그는 여기서
```

traceback이 `launcher/api.py:279 -> agent.run()`이었습니다. **에이전트 단계**라
실패 노드에는 `[probe rN]` 줄이 아예 없습니다.

**그리고 이 숫자가 맞지 않습니다.**

```
--nnodes=8  ->  min=max=8. 8개가 모여야 완료
실제로는     ->  nranks 56 = 7노드가 완료되고 Destroy COMPLETE
```

7노드로는 8노드 rendezvous가 완료될 수 없습니다. **하나의 실행이 아니라는 뜻입니다.**
`nranks 56`을 만든 라운드와 `.27`이 합류하려던 라운드가 **서로 다릅니다.**

그게 가능했던 이유:

- 모든 실행이 rendezvous id **`none`을 공유** (이전 로그의 `rendezvous 'none'`)
- 프로브는 `docker run --rm`을 **`--name` 없이** 씀 -> 중복 실행을 막는 것이 없음

즉 **이전 실행의 컨테이너가 살아 있으면 같은 엔드포인트·같은 id의 별개 라운드가 겹칩니다.**

---

## STEP 1 — rendezvous 격리 확인 (지금 할 일)

**`git pull` 필요.** 두 가지를 새로 봅니다.

```bash
./scripts/nccl_probe.sh --hosts-file hostfile --image $IMG
```

**(a) 잔존 리스너** — 이전 실행의 컨테이너가 29500을 잡고 있으면, 새로 합류하는 노드가
**그쪽 store로 갑니다.** 지금까지 아무 검사도 이걸 못 봤습니다. 포트가 응답하니
도달성 검사는 통과하거든요.

```
  node19: [STALE] something already listens on 29500: users:(("python",pid=...))
  node19: containers running: mlperf-train-...
```

**(b) rendezvous id** — 지금까지 모든 실행이 id `none`을 공유했습니다(이전 로그의
`rendezvous 'none'`). 이제 실행마다 고유 id를 씁니다. 다른 실행과 섞일 수 없습니다.

이 둘 중 하나가 원인이었다면 이번에 통과하거나, `[STALE]`로 이름이 나옵니다.

---

## STEP 2 — 그래도 안 되면: rendezvous 내부 로그

여기까지 오면 추측을 멈추고 torch가 뭘 하는지 봐야 합니다.

```bash
TORCH_DISTRIBUTED_DEBUG=DETAIL LOGLEVEL=INFO \
./scripts/nccl_probe.sh --hosts node19,node27 --image $IMG 2>&1 | tee /tmp/rdzv.log
```

**2노드로 좁혀서** 돌리세요. rank 0과 문제 노드만. 볼 것:

```
Rendezvous complete for workers. Result: restart_count=... master_addr=...
The node 'xxx' has joined round N of the rendezvous 'yyy' as rank R of W
```

`.27`이 **join은 하는데 evict되는지**, 아니면 **join 자체를 못 하는지**가 여기서 갈립니다.
그 로그를 `Errors`에 주세요.

---

## 도구 정리

| 스크립트 | 용도 |
|---|---|
| `node_diff.sh` | **노드끼리 비교 — 다른 것만** (신규) |
| `node_check.sh --host H --image I` | 노드 하나의 전제조건 |
| `acs_check.sh --host H` | PCIe ACS 상태 (읽기 전용) |
| `nccl_probe.sh --hosts-file F --image I` | NCCL만 30초 검증 + 참여/대역폭 표 |
| `preflight.sh` | 관리 서버 쪽 |
| `run_multi_node.sh` / `run_single_node.sh` | 실행 |

프로브가 이제 마지막에 내는 것:

```
PARTICIPATING NODES   어느 노드가 몇 rank로 참여했는지
ALL-REDUCE BANDWIDTH  algbw / busbw (busbw 가 world size 간 비교 가능한 값)
PER-HOST RESULT       호스트별 exit + 실패 사유 한 줄
world formed: 56/64 ranks, 7/8 nodes
```

---

## 이번 라운드들에서 고친 것

| 커밋 | 내용 |
|---|---|
| `c23dfbb`, `fe3288b` | bastion 경유 — UI에서 망 선택, 체인은 `.env` |
| `266a1f0` | `--hosts-file` / `MLPERF_HOSTFILE` |
| `aa46bbb` | 프로브도 B300이면 `NCCL_NET_PLUGIN=none` 자동 |
| `bd53a12` | `exec` 대신 종료 코드 보고 (조용한 종료 제거) |
| `521b198` | 값 없는 플래그를 이름과 함께 거부 |
| `f5e87c4` | **GBS를 노드 수에서 파생** |
| `e3be2c9` | 전 호스트 GPU 수 검증 |
| `42cc79f` | **`container.log` — 학습 출력 전량 보존** |
| `be32d17`, `5ff7d9a` | rendezvous 도달성 사전 검사 |
| `fb1215f`, `d0e3015` | 참여/대역폭/실패사유 표, 정상 노드를 실패로 찍던 버그 수정 |
| `ae7d479` | 프로브도 이미지 사전 로드 후 대기 |
| **`fdaa5c6`** | **`read_timeout` — 60초 절단의 실제 원인** |
| `ec007e8` | `node_diff.sh` |
| (이번) | 시계 검사 경고로 완화, 고유 rendezvous id, 잔존 리스너 검사 |

---

## 남은 이슈

| 항목 | 상태 |
|---|---|
| `.27/.29/.30` 미합류 | **미해결.** 네트워크·GPU·이미지·드라이버·시계 전부 배제됨 |
| **SHARP 부재** | B300은 HPC-X 플러그인을 끄므로 in-network reduction 없음. 정식 측정 전 이미지 교체 여부 결정 |
| 8노드 스케일링 측정 | 1/2/4/8 스텝 시간 비교 (미착수) |
| llama2_70b_lora | B300에서 미실행 |
| `frontend/app.jsx` | 어디서도 로드 안 되는 잔존 파일 (정리 보류) |

---

## 참고

`Errors`에 노드 IP·호스트명·사내 레지스트리 주소가 들어가 있습니다.
이 저장소는 public입니다. 원하시면 익명화해 드리겠습니다.
