# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (11회차)
- 이번 용의자: **HPC-X의 외부 NCCL 플러그인** (`libnccl-net.so`)

---

## 1. 프로브가 크래시 지점을 찍었습니다

30초 만에 재현됐고, NCCL이 죽기 직전 마지막 줄까지 남았습니다.

```
NCCL INFO NET/Plugin: Loaded net plugin NCCL RDMA Plugin v10 (v10)
NCCL INFO NET/Plugin: Loaded collnet plugin SHARP (v10)
NCCL INFO Successfully loaded external network plugin /opt/hpcx/nccl_rdma_sharp_plugin/lib/libnccl-net.so
NCCL INFO P2P plugin v10 IBext_v10
NCCL INFO Using network NCCL RDMA Plugin v10
NCCL INFO ncclCommInitRankConfig ... rank 0 nranks 1 ... Init START
NCCL INFO MNNVL busId 0x1a000 fabric UUID 0.0 cliqueId 0x0 state 3 healthMask 0x80
Fatal Python error: Segmentation fault
```

`Init START`는 있는데 **`Init COMPLETE`가 없습니다.** `ncclCommInitRankConfig` 한가운데서
죽는 게 로그로 확정됐습니다.

---

## 2. 죽은 가설 정리

| 가설 | 근거 |
|---|---|
| 드라이버 | **정상.** 580.173.02 = r580, CUDA 13.0 지원. `cudaDriverVersion 13000` |
| MNNVL / IMEX | **폐기.** `cliqueId 0x0`, `fabric UUID 0.0` — MNNVL 소속 아님. `NCCL_MNNVL_ENABLE=0`도 무효 |
| 8-GPU 토폴로지 | **폐기.** 1랭크에서 재현 |
| NVSwitch fabric | **폐기.** State Completed / Success |
| `sm_103` | **폐기.** 프로브가 `cuda:0 NVIDIA B300 SXM6 AC sm_103`까지 정상 인식 |
| NeMo / Megatron / TE | **폐기.** 프로브엔 이것들이 아예 없습니다 |

`NCCL_MNNVL_ENABLE=0` / `NCCL_CUMEM_ENABLE=0` / `NCCL_NVLS_ENABLE=0` / `NCCL_IB_DISABLE=1`
**네 개가 전부 실패**한 게 오히려 답에 가깝습니다. 이 변수들은 전부 **NCCL 내부** 경로를
끄는 것들이고, 하나도 안 통한다는 건 문제가 NCCL 내부가 아니라는 뜻입니다.

---

## 3. 남은 것 — 외부 플러그인

로그가 가리키는 건 NCCL 본체가 아니라 **HPC-X가 끼워 넣은 외부 플러그인**입니다.

```
/opt/hpcx/nccl_rdma_sharp_plugin/lib/libnccl-net.so   (v10)
```

이게 유력한 이유:

1. **외부 바이너리입니다.** NCCL 2.28.3과 따로 빌드됐고, 플러그인 ABI가 안 맞으면
   NCCL이 NULL 함수 포인터를 그대로 호출합니다 → 정확히 `address (nil)` 널 역참조.
2. **랭크 수와 무관하게 로드됩니다.** 1랭크에서 재현되는 게 설명됩니다.
3. **위 네 변수 중 어느 것도 이 플러그인을 안 내립니다.** 전부 실패한 게 설명됩니다.
4. `NCCL_IB_DISABLE=1`도 소용없습니다 — 그건 NCCL 내장 IB 전송을 끄는 것이지
   외부 net 플러그인을 언로드하지 않습니다.

### 곁들여 눈에 띈 것

```
[probe r0] ... nccl 2.27.7        <- PyTorch가 빌드된 NCCL 헤더 버전
NCCL INFO NCCL version 2.28.3     <- 실제로 로드된 NCCL
```

torch는 2.27.7로 빌드됐는데 런타임은 2.28.3입니다. NCCL은 major 2 안에서 ABI 호환을
지키므로 보통은 문제없지만, **플러그인까지 끼면 얘기가 달라집니다.**
플러그인 v10은 또 다른 세 번째 버전 기준으로 빌드된 물건입니다.

---

## 준비

**`git pull` 필요** (`fcab584` — `NCCL_NET_PLUGIN` 등 forward 추가).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

NODE=node25
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell
```

**먼저 셸 정리를 한 번 해주세요.** 지난 실행 로그에 이렇게 찍혔습니다.

```
env into container: ... NCCL_IB_DISABLE= NCCL_IB_HCA= NCCL_SOCKET_IFNAME= ...
```

셸에 빈 값으로 export가 남아 있습니다. 지금 테스트엔 무해하지만 뒤에서 헷갈립니다.

```bash
unset NCCL_IB_DISABLE NCCL_IB_HCA NCCL_SOCKET_IFNAME
```

---

## STEP 1 — 외부 플러그인 끄기 (30초, 이번 라운드의 본 게임)

```bash
NCCL_NET_PLUGIN=none NCCL_DEBUG=INFO \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/nccl_probe.sh --host $NODE --image $IMG --gpus 1
```

**로그에서 확인할 것** — 이 줄이 **사라져야** 적용된 것입니다.

```
NCCL INFO Successfully loaded external network plugin /opt/hpcx/...
```

| 결과 | 결론 |
|---|---|
| `[probe r0] ALL OK -- 1 ranks` | **원인 확정.** HPC-X 플러그인입니다 |
| 여전히 signal 11 | 플러그인 아님 → STEP 2 |

---

## STEP 2 — 안 되면 SHARP collnet도 (30초)

```bash
NCCL_NET_PLUGIN=none NCCL_COLLNET_ENABLE=0 NCCL_DEBUG=INFO \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/nccl_probe.sh --host $NODE --image $IMG --gpus 1
```

그래도 죽으면 플러그인 계열은 전부 아웃입니다. 그 로그를 주세요.

---

## STEP 3 — 8장으로 확대 (STEP 1이나 2가 통과했을 때)

1장이 되면 8장도 되는지 봅니다. 여기서 갈리면 그것도 정보입니다.

```bash
NCCL_NET_PLUGIN=none NCCL_DEBUG=INFO \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
./scripts/nccl_probe.sh --host $NODE --image $IMG
```

통과하면 바로 학습으로 갑니다.

```bash
NCCL_NET_PLUGIN=none \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1 \
MLPERF_TRAIN_IMAGE_TAR=$TAR \
./scripts/run_single_node.sh --host $NODE \
  --benchmark llama31_8b --docker-image $IMG \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

---

## STEP 4 — 플러그인 정보 (ssh만, `git pull` 불필요)

원인이 확정되면 근거로 남길 것들입니다. STEP 1과 병행해도 됩니다.

```bash
ssh $NODE "docker run --rm $IMG bash -c '
  ls -la /opt/hpcx/nccl_rdma_sharp_plugin/lib/
  cat /opt/hpcx/VERSION 2>/dev/null
  strings /opt/hpcx/nccl_rdma_sharp_plugin/lib/libnccl-net.so | grep -iE \"^2\\.[0-9]+\\.[0-9]+\" | sort -u | head
'"
```

---

## STEP 5 — 회신

`Errors`에 붙여주세요.

1. STEP 1 — 통과 여부 + `NCCL_DEBUG=INFO` 로그
2. STEP 2 — 했다면 그 결과
3. STEP 4 — 플러그인 버전

STEP 1이 통과하면 `NCCL_NET_PLUGIN=none`을 런처에 어떻게 넣을지 정리해서 올리겠습니다.
(단일 노드 학습에는 이 플러그인이 필요 없습니다. 멀티 노드 IB 성능에는 영향이 있을 수
있어서, 기본값으로 박기보다 GPU 타입 조건부로 두는 쪽을 제안드릴 생각입니다.)

---

## 이미 확인된 것 (다시 볼 필요 없음)

| 항목 | 결과 |
|---|---|
| 크래시 위치 | **`ncclCommInitRankConfig` 내부.** `Init START` 후 `Init COMPLETE` 없음 |
| 마지막 로그 | `MNNVL ... cliqueId 0x0 state 3 healthMask 0x80` |
| 크래시 최소 조건 | **GPU 1장, 1랭크.** 프로브(NCCL init + all-reduce)만으로 재현 |
| 크래시 모양 | 널 포인터 역참조 (`address not mapped ... at address (nil)`) |
| 드라이버 | 580.173.02 (r580). `cudaDriverVersion 13000`. **정상** |
| MNNVL / IMEX | **무관.** `cliqueId 0x0`, MNNVL 소속 아님 |
| `NCCL_MNNVL_ENABLE=0` | 무효 |
| `NCCL_CUMEM_ENABLE=0` | 무효 |
| `NCCL_NVLS_ENABLE=0` | 무효 |
| `NCCL_IB_DISABLE=1` | 무효 |
| GPU 인식 | `NVIDIA B300 SXM6 AC sm_103` 정상 |
| NeMo / Megatron / TE / 벤치마크 | **무관.** 프로브에 없음 |
| 8-GPU 토폴로지 / NVLink / P2P | **무관.** 1랭크 재현 |
| NVSwitch fabric | 정상 (fabricmanager active, State Completed / Success) |
| `dmesg` Xid | 없음 |
| blackwell 이미지 | `-sm90`과 동일 빌드 |
| llama31_8b 정밀도 | `bf16`만 허용 — 수정 완료(`d4a11f3`) |
| llama31_8b TP=1 | sequence parallelism 자동 해제 — 수정 완료(`19cad5e`) |
| 호스트 IB | NIC 전부 ACTIVE / link up, `mlx5_0`~`mlx5_15` 인식 |
| UCX | 원인 아님. 4프레임 백트레이스는 전역 시그널 핸들러였음 |
| 런처 코드 | `mlperf_run.sh` / `common.sh` 원본과 동일 |

---

## 참고 — 정리해두면 좋은 것

`Errors`에 노드 IP(`node25`), 호스트명(`node-26049`), 사내 레지스트리
주소(`registry.internal`)가 들어가 있습니다. 이 저장소는 public입니다.
원하시면 익명화해 드리겠습니다.
