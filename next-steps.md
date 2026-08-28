# Next Steps

- 갱신: 2026-08-28 (18회차)
- 상태: **2노드 학습(TP=8 PP=2) 완주.** 다음은 8노드 확장

---

## 1. 지금까지

| 단계 | 상태 |
|---|---|
| 단일 노드 NCCL (1장 / 8장) | 통과 |
| 단일 노드 학습 llama31_8b 8장 | **통과** |
| 멀티노드 NCCL — Socket | 통과 (진단용, 쓰지 않음) |
| 멀티노드 NCCL — **IB + GDR** | **통과** |
| 멀티노드 학습 (2노드, TP=8 PP=2) | **통과 — 완주** |

### 해결된 원인 세 가지

| 증상 | 원인 | 조치 |
|---|---|---|
| `Unsupported precision bf16-mixed` | 8b `pretrain.py`는 `bf16`만 받음 | `d4a11f3` |
| SIGSEGV (`ncclCommInitRankConfig`) | HPC-X `libnccl-net.so` ↔ NCCL 2.28.3 불일치 | `489dc11` — B300은 `NCCL_NET_PLUGIN=none` |
| IB `status=4` (local protection error) | **PCIe ACS**가 NIC↔GPU P2P DMA 차단 | ACS 해제 — **완료** |

---

## 2. 직전 라운드에서 고친 것

### `npy_index` — 멀티노드 학습이 죽던 원인

```
FileNotFoundError: /npy_index/...-GPTDataset-train-document_index.npy
```

`/npy_index`가 `${LOG_DIR}/npy_index`에서 마운트되는데, `LOG_DIR`에는 **각 노드의
타임스탬프와 호스트명**이 들어갑니다. 노드마다 다른 빈 디렉터리를 본 겁니다.
rank 0이 자기 노드에 인덱스를 만들고, 다른 노드 랭크들은 빈 디렉터리를 읽었습니다.

**PP=2 때문이 아닙니다.** PP=2가 NCCL을 지나 데이터셋 단계까지 간 첫 멀티노드
실행이라 거기서 처음 드러난 것뿐이고, PP=1이어도 같은 에러가 났을 겁니다.

이제 모든 노드가 같은 값을 받는 `RUN_ID`로 키를 잡습니다 (`5cbdc5b`).

```
[INFO] npy_index_dir=${LOG_ROOT}/npy_index_${RUN_ID} (must be shared across nodes)
```

`LOG_ROOT`가 노드-로컬이면 `MLPERF_NPY_INDEX_DIR`로 따로 지정하세요.

### `NPY_INDEX_DIR` unbound variable

위 수정에서 `mkdir` 줄이 `CONTAINER_CMD` 안, 즉 **컨테이너 내부**에 있었습니다.
`NPY_INDEX_DIR`은 호스트 단계 변수라 컨테이너에는 없고, `set -u`에 걸렸습니다.

컨테이너 안에서는 마운트 지점인 `/npy_index`를 쓰고, 호스트 쪽 디렉터리는
`docker run` 전에 만들도록 고쳤습니다.

### 이미지 로드 순서 (`9e6a2c8`)

전에는 "tar가 있다"까지만 확인하고 넘어가서, N1이 `docker run`으로 들어간 뒤
N2가 그제서야 tar를 풀었습니다. rendezvous가 그걸 기다려주지 않습니다.

이제 **모든 노드에서 로드를 끝낸 뒤에** 실행합니다. 로드는 병렬입니다.

```
[INFO] preparing image on 2 host(s): <image>
  node19: already loaded
  node20: loaded from /mgmt/.../llama31_8b-pyt-blackwell.tar
[INFO] image ready on all 2 host(s)
```

### tar 파일명 (`6b421a6`)

제가 문서에 언더스코어로 잘못 적었습니다. 하이픈이 맞습니다.

```
llama31_8b-pyt-blackwell.tar
```

### 로그 경로 (`14c29a1`)

`.env`에서 지정합니다. `MLPERF_LOG_ROOT` > `POC_PLATFORM_ROOT` > `/opt/poc-platform`.
`POC_PLATFORM_ROOT`가 이미 `/mgmt/...`면 아무것도 안 하셔도 따라갑니다.

---

## 준비

**`git pull` 필요** (`d916a99`).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

N1=node19
N2=node20
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b-pyt-blackwell.tar
```

---

## 노드 목록

8개를 커맨드라인에 나열하면 실수하기 쉬우니 변수로 둡니다.

```bash
HOSTS=node19,node20,<노드3>,<노드4>,<노드5>,<노드6>,<노드7>,<노드8>
```

`--hosts`의 **순서가 rank를 정합니다.** 첫 번째가 rank 0이고 `MASTER_ADDR`가 됩니다.

---

## STEP 1 — 8노드 사전 점검 (2분)

2노드에서 겪은 것들(이미지 없음, ACS, tar 경로)이 새 노드 6대에서 그대로 반복될 수
있습니다. 학습 전에 한 번에 걸러냅니다.

```bash
for h in ${HOSTS//,/ }; do
  echo "=========== $h"
  ./scripts/node_check.sh --host $h --image $IMG
done
```

각 노드에서 볼 것:

- 드라이버 / fabricmanager / `/dev/infiniband` — `MISS` 없을 것
- **ACS** — 새 노드도 꺼져 있어야 합니다
- 데이터가 같은 경로로 보일 것

```bash
for h in ${HOSTS//,/ }; do
  printf '%-16s ' "$h"
  ssh $h 'ls /mgmt/server/poc-platform/data/training_llama31_8b/8b >/dev/null 2>&1 && echo "data OK" || echo "data MISSING"'
done
```

---

## STEP 2 — 8노드 NCCL 프로브 (30초) ← 학습 전에 반드시

**5분짜리 학습으로 디버깅하지 않기 위한 단계입니다.** 지금까지 이게 다 잡아냈습니다.

```bash
NCCL_DEBUG=INFO UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/nccl_probe.sh --hosts $HOSTS --image $IMG
```

**`all_reduce OK (= 64)`** 가 나와야 합니다. 64가 아니면 랭크가 빠진 것입니다.

```
[INFO] per-host result:
  rank 0   node19    exit=0
  ...
  rank 7   <노드8>          exit=0
[INFO] multi-node NCCL OK across 8 nodes
```

실패하면 **어느 rank인지**가 로그에 나옵니다. 그 노드만 2노드 프로브로 좁히세요.

```bash
./scripts/nccl_probe.sh --hosts node19,<의심 노드> --image $IMG
```

---

## STEP 3 — 스케일링 측정 (1 → 2 → 4 → 8)

**`GBS=1024`를 고정**하고 노드 수만 바꿉니다. 그래야 스텝 시간이 곧 speedup입니다.

| 노드 | WORLD | TP | PP | DP | GBS | grad_accum |
|---|---|---|---|---|---|---|
| 1 | 8 | 8 | 1 | 1 | 1024 | 1024 |
| 2 | 16 | 8 | 1 | 2 | 1024 | 512 |
| 4 | 32 | 8 | 1 | 4 | 1024 | 256 |
| 8 | 64 | 8 | 1 | **8** | 1024 | 128 |

네 구성 모두 런처 검증을 통과합니다.

```bash
# 8노드
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_multi_node.sh --hosts $HOSTS \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --cp 1 --mbs 1 --gbs 1024 --max-steps 10

# 4노드 / 2노드는 --hosts 만 줄이면 됩니다 (나머지 인자 동일)
```

**왜 PP=1인가** — DP가 커져야 노드 간 **gradient allreduce**가 커지고, 그게 멀티노드
스케일링에서 실제로 재고 싶은 것입니다. PP=2도 돌지만(8노드면 DP=4) allreduce가
줄어들어 스케일링 측정으로는 덜 적합합니다.

---

## STEP 4 — 결과 해석

스텝 시간을 노드 수에 대해 보세요.

| 관찰 | 의미 |
|---|---|
| 노드 2배 → 스텝 시간 거의 절반 | 정상 스케일링 |
| 4→8에서 개선이 꺾임 | allreduce가 병목. **SHARP 부재가 여기서 드러납니다** |
| 특정 노드 수에서만 급락 | 그 노드 세트의 IB 경로 문제. 프로브로 좁히세요 |

**8노드는 SHARP 부재가 가장 크게 드러나는 지점입니다.** allreduce 트래픽이 노드 수에
비례해 커지는데, in-network reduction이 바로 그걸 줄여주는 기능이라서요.
정식 측정을 하실 거면 이 수치를 근거로 이미지 교체 여부를 정하시면 됩니다.

---

## STEP 5 — 회신

1. STEP 2 — 8노드 프로브 `= 64` 통과 여부
2. STEP 3 — 1/2/4/8 스텝 시간
3. STEP 1에서 걸린 노드가 있었는지

---

## PP=2에 대해

**제약은 통과합니다.** `TP×PP×CP = 8×2×1 = 16 = WORLD` → `DP=1`, `grad_accum=256`.

다만 **DP가 1이 됩니다.**

| | 노드 간에 흐르는 것 |
|---|---|
| `PP=1, DP=2` | **gradient allreduce** — 대용량, 대역폭 위주 |
| `PP=2, DP=1` | 파이프라인 activation P2P — 소량, 지연 위주 |

방금 고친 IB/GDR 경로와 SHARP가 관여하는 지점이 **allreduce**입니다.
PP=2로 가면 그게 거의 사라져서 **멀티노드 통신을 시험하는 구성이 아니게 됩니다.**
PP는 모델이 안 들어갈 때 쓰는 카드이고, llama31_8b는 TP=8로 충분합니다.

병렬화 전략 비교가 목적이면 STEP 3이 끝난 뒤에 돌려보세요.
그때 `virtual_pipeline` 관련 에러가 나면 이렇게 넘깁니다. (런처는 PP=1일 때만
자동으로 꺼줍니다.)

```bash
--extra-overrides "++model.virtual_pipeline_model_parallel_size=null"
```

---

## 무시해도 되는 경고

### `NET/IB : Cannot use physical device 18, max 16`

이 노드가 IB 디바이스를 **16개보다 많이** 노출하는데, NCCL 내부 물리 디바이스
테이블 상한이 16이라 넘는 것마다 한 줄씩 찍는 것입니다. **동작에는 문제없습니다.**

- 열거(enumeration) 시점의 경고이고, `NCCL_IB_HCA` 필터링은 그 **뒤에** 일어납니다.
  그래서 런처가 HCA를 지정해도 이 줄은 그대로 나옵니다.
- 16개면 이 작업에 필요한 것보다 훨씬 많습니다.

**한 가지만 확인해 두면 좋습니다** — NCCL이 실제로 무엇을 골랐는지.

```
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB/SHARP [1]mlx5_1:1/IB/SHARP ...
```

이 노드는 `mlx5_2, 3, 12, 13`이 **RoCE**이고 나머지가 IB/SHARP입니다.
16개 자를 때 IB가 빠지고 RoCE만 남았다면 느린 경로를 타게 됩니다.
위 줄이 IB 위주면 그대로 두시면 됩니다.

조용하고 결정적으로 만들려면 직접 못 박으면 됩니다. (런처는
`nvidia-smi topo -m`으로 호스트별 자동 바인딩을 하지만, 열거 경고는 남습니다.)

```bash
NCCL_IB_HCA='mlx5_0,mlx5_1,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_14,mlx5_15'
```

---

## 남은 이슈

| 항목 | 상태 |
|---|---|
| **SHARP 부재** | B300은 HPC-X 플러그인을 끄므로 in-network reduction 없음. 정식 측정 전에 이미지 교체 여부 결정 필요 |
| llama2_70b_lora | B300에서 아직 안 돌려봄. 8b가 끝나면 |
| `NCCL_IB_DISABLE=1` 무시됨 | 진단 중 발견. 지금 막히는 건 없음, 원인 미상 |

---

## 이 건에서 고친 것들

| 커밋 | 내용 |
|---|---|
| `d4a11f3` | llama31_8b 정밀도 `bf16-mixed` → `bf16` |
| `19cad5e` | TP=1일 때 sequence parallelism 자동 해제 |
| `76a7fc8` | `MLPERF_TRAIN_IMAGE_TAR` |
| `489dc11` | **B300 `NCCL_NET_PLUGIN=none`** — SIGSEGV 해결 |
| `a3d213a`, `2599300` | `nccl_probe.sh` — NCCL만 30초 검증, 단일/멀티 |
| `a4fa8b6` | `acs_check.sh` — **IB `status=4` 원인 규명** |
| `14c29a1` | 로그 루트를 `.env`에서 지정 |
| `c99e027`, `9e6a2c8` | 모든 노드 이미지 로드 완료 후 실행 |
| `5cbdc5b` | **`npy_index`를 노드 간 공유** — 멀티노드 학습 |
| `d916a99` | 그 수정의 `NPY_INDEX_DIR` unbound variable 수정 |

---

## 참고 — 정리해두면 좋은 것

`Errors`에 노드 IP, 호스트명, 사내 레지스트리 주소가 들어가 있습니다.
이 저장소는 public입니다. 원하시면 익명화해 드리겠습니다.
