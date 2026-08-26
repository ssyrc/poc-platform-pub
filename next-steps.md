# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (12회차)
- **원인 확정: HPC-X가 NCCL에 끼워 넣는 외부 플러그인**

---

## 1. 원인

```
/opt/hpcx/nccl_rdma_sharp_plugin/lib/libnccl-net.so   ("NCCL RDMA Plugin v10")
```

이 플러그인이 이 이미지의 **NCCL 2.28.3**과 맞지 않아 `ncclCommInitRankConfig` 안에서
널 포인터를 역참조합니다. `NCCL_NET_PLUGIN=none`으로 안 끼우면 정상 동작합니다.

증거가 다 맞물립니다.

| 관찰 | 설명 |
|---|---|
| `at address (nil)` 널 역참조 | ABI 불일치로 NULL 함수 포인터 호출 |
| GPU **1장**에서도 재현 | 플러그인은 랭크 수와 무관하게 로드됨 |
| `Init START` 후 `Init COMPLETE` 없음 | comm 초기화 도중 사망 |
| NCCL 내부 변수 4개 전부 무효 | 문제가 NCCL 내부가 아니었음 |
| `NCCL_NET_PLUGIN=none` → 통과 | 플러그인만 빼면 됨 |

**한 달 가까이 아키텍처·정밀도·토폴로지를 의심했지만, 전부 아니었습니다.**
(그 과정에서 정밀도 버그와 TP=1 버그는 실제로 나왔고 고쳤습니다.)

---

## 2. 무엇을 잃는가

`NCCL_NET_PLUGIN=none`은 NCCL이 **자체 IB/RDMA 전송**으로 돌아가게 합니다.

| | 영향 |
|---|---|
| 단일 노드 | **없습니다.** 이 플러그인은 노드 간 통신용입니다 |
| 멀티 노드 | 동작합니다. NCCL 내장 IB가 RDMA를 그대로 씁니다 |
| 잃는 것 | **SHARP** (스위치 내 in-network reduction). 멀티 노드 allreduce가 느려집니다 |

즉 **성능은 일부 손해, 동작은 정상**입니다.
근본 해결은 NCCL 2.28과 맞는 HPC-X로 올린 이미지를 쓰는 것인데, 폐쇄망에서 이미지를
새로 빌드해야 하므로 지금 당장의 답은 아닙니다.

---

## 3. 런처에 반영했습니다

`mlperf_train_v51.sh`(두 벤치마크 분기), `mlperf_train_v41.sh`에 넣었습니다.

```bash
if [[ "${MLPERF_GPU_TYPE:-}" == "B300" && -z "${NCCL_NET_PLUGIN:-}" ]]; then
  export NCCL_NET_PLUGIN="none"
fi
```

- **B300에서만** 적용합니다. 크래시가 증명된 곳이 거기뿐이고,
  다른 GPU에서는 SHARP를 괜히 버릴 이유가 없습니다.
- **직접 지정하면 그대로 존중합니다.** 양방향 모두 덮어쓸 수 있습니다.
- 적용되면 로그에 한 줄 남습니다.

```
[CONTAINER] B300: NCCL_NET_PLUGIN=none (HPC-X plugin crashes ncclCommInitRankConfig; using NCCL built-in IB, no SHARP)
```

---

## 준비

**`git pull` 필요** (`아래 커밋` — B300 기본값 반영).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

NODE=node25
TAR=/mgmt/server/poc-platform/data/dockerimgs/llama31_8b_pyt-blackwell.tar
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
```

---

## STEP 1 — 프로브 8장 (30초)

1장은 됐으니 8장을 확인합니다. 여기서 갈리면 그것도 정보입니다.

```bash
NCCL_NET_PLUGIN=none NCCL_DEBUG=INFO \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/nccl_probe.sh --host $NODE --image $IMG
```

`[probe r0] ALL OK -- 8 ranks`가 나오면 통과입니다.

---

## STEP 2 — 실제 학습 (llama31_8b, 8장)

이제 `NCCL_NET_PLUGIN`을 안 줘도 됩니다. B300이면 런처가 알아서 넣습니다.

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

**로그에서 확인할 것**

```
[CONTAINER] B300: NCCL_NET_PLUGIN=none ...     <- 기본값이 걸렸는지
++trainer.precision=bf16                        <- 정밀도 수정이 살아있는지
```

---

## STEP 3 — llama2_70b_lora (원래 목표였던 벤치마크)

8b가 돌면 원래 하려던 것으로 돌아갑니다. 이미지가 다릅니다.

```bash
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama2_70b_lora \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

이건 `-sm90` 기본 이미지를 씁니다. 같은 HPC-X 플러그인이 들어 있으므로
같은 수정으로 같이 풀릴 것으로 봅니다. 아니면 그 로그를 주세요.

---

## STEP 4 — 멀티 노드 (단일 노드가 다 되고 나서)

여기서부터 SHARP 손실이 실제로 드러납니다. 동작은 해야 합니다.

```bash
./scripts/run_multi_node.sh --hosts <노드1>,<노드2> \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 256 --max-steps 10
```

---

## STEP 5 — 회신

1. STEP 1 — 8랭크 프로브 통과 여부
2. STEP 2 — 학습이 스텝을 도는지, 몇 스텝까지
3. STEP 3 — lora도 같이 풀리는지

---

## 이 건에서 실제로 고친 것들

| 커밋 | 내용 |
|---|---|
| `d4a11f3` | llama31_8b 정밀도 — `bf16-mixed` → `bf16` (pretrain.py가 `bf16`만 허용) |
| `19cad5e` | TP=1일 때 sequence parallelism 자동 해제 |
| `76a7fc8` | `--docker-image`에 맞는 tar를 `MLPERF_TRAIN_IMAGE_TAR`로 지정 가능 |
| `a3d213a` | `scripts/nccl_probe.sh` — NCCL만 30초에 판정하는 프로브 |
| `cd1e79e`, `43b7edb`, `fcab584` | NCCL/UCX 디버그 변수 forward |
| (이번) | B300에서 `NCCL_NET_PLUGIN=none` 기본 적용 |

---

## 확인된 사실 (기록용)

| 항목 | 결과 |
|---|---|
| **원인** | **HPC-X `libnccl-net.so` v10 ↔ NCCL 2.28.3 불일치** |
| **해결** | **`NCCL_NET_PLUGIN=none`** (B300 기본값으로 반영) |
| 크래시 위치 | `ncclCommInitRankConfig` 내부 |
| 최소 재현 | GPU 1장, 1랭크, NCCL init + all-reduce |
| 드라이버 | 580.173.02 (r580) — 정상 |
| MNNVL / IMEX | 무관. `cliqueId 0x0` |
| `sm_103` | 무관. `sm_100` cubin이 minor 상위 호환 |
| blackwell 이미지 | `-sm90`과 동일 빌드 |
| NVSwitch fabric | 정상 |
| `dmesg` Xid | 없음 |
| NeMo / Megatron / TE | 무관 |
| torch 빌드 NCCL | 2.27.7 (런타임은 2.28.3) — 지금 문제와는 별개 |

---

## 참고 — 정리해두면 좋은 것

`Errors`에 노드 IP(`node25`), 호스트명(`node-26049`), 사내 레지스트리
주소(`registry.internal`)가 들어가 있습니다. 이 저장소는 public입니다.
원하시면 익명화해 드리겠습니다.
