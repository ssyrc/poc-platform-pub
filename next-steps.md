# Next Steps

- 갱신: 2026-08-28 (19회차)
- 상태: **2노드 학습 완주.** 8노드에서 `node27/29/30`이 all-reduce에 합류 못 함
- 지금 할 일: 프로브 반복 대신 **서버단 차이 확인**

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

## STEP 1 — 노드끼리 비교 (지금 할 일)

프로브를 더 돌리지 않고, `.27/.29/.30`이 **뭐가 다른지** 봅니다.

```bash
./scripts/node_diff.sh --hosts-file hostfile
```

같은 값은 접히고 **다른 것만** 나옵니다. **문제 노드 3대가 한 그룹으로 묶여 나오면 그게 원인**입니다.

보는 항목: 드라이버·GPU 수/모델·ECC·persistence, fabricmanager·IMEX·fabric state,
`peermem`·`uvm`, **OFED·IB 디바이스 수·Active 링크 수·링크 속도**, ACS redirect,
docker·nvidia-ctk·docker root 여유공간, memlock, **시계 오차**.

> **`peermem` 미로드는 결함이 아닙니다.** 이 NCCL은 GPU 메모리를 **dma-buf**로
> 등록합니다(`DMA-BUF is available on GPU device 0`). `peermem`은 대체 경로입니다.
> 다만 **노드마다 다르면** 그건 볼 만한 차이입니다.

---

## STEP 2 — 차이가 없으면 2노드로 좁히기

```bash
for h in node27 node29 node30; do
  echo "=== rank0 + $h"
  ./scripts/nccl_probe.sh --hosts node11,$h --image $IMG
done
```

2노드로도 안 되면 그 노드 고유 문제, 되는데 8노드에서만 빠지면 규모/타이밍 문제입니다.

---

## STEP 3 — 8노드 재시도 (STEP 1·2가 정리된 뒤)

```bash
./scripts/nccl_probe.sh --hosts-file hostfile --image $IMG
```

`world formed: 64/64 ranks, 8/8 nodes`가 목표입니다. 부족하면 더 넓혀보세요.

```bash
PROBE_RDZV_TIMEOUT=1200 ./scripts/nccl_probe.sh --hosts-file hostfile --image $IMG
```

통과하면 학습으로:

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_multi_node.sh --hosts-file hostfile \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --cp 1 --mbs 1 --max-steps 10
```

`--gbs`는 **생략하세요.** 노드 수에서 파생됩니다(`MBS x DP x grad_accum`, grad_accum 기본 128).
1/2/4/8노드가 128/256/512/1024가 되어 GPU당 일이 일정하게 유지됩니다.

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

---

## 남은 이슈

| 항목 | 상태 |
|---|---|
| `.27/.29/.30` 미합류 | `read_timeout` 수정 후 재확인 필요. 안 되면 STEP 1의 차이 |
| **SHARP 부재** | B300은 HPC-X 플러그인을 끄므로 in-network reduction 없음. 정식 측정 전 이미지 교체 여부 결정 |
| 8노드 스케일링 측정 | 1/2/4/8 스텝 시간 비교 (미착수) |
| llama2_70b_lora | B300에서 미실행 |
| `frontend/app.jsx` | 어디서도 로드 안 되는 잔존 파일 (정리 보류) |

---

## 참고

`Errors`에 노드 IP·호스트명·사내 레지스트리 주소가 들어가 있습니다.
이 저장소는 public입니다. 원하시면 익명화해 드리겠습니다.
