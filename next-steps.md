# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26 (3회차)
- 대상 증상: training v5.1 단일노드 실행 중 segfault (B300)

---

## 이번 회차의 핵심 발견 — UCX는 범인이 아닙니다

백트레이스가 4프레임뿐이고 **애플리케이션 프레임이 하나도 없습니다.**

```
0 libucs.so.0(ucs_handle_error+0x2e4)   ← UCX 시그널 핸들러 진입
1 libucs.so.0(+0x3796a)                 ← 핸들러 내부
2 libucs.so.0(+0x37ba8)                 ← 핸들러 내부
3 libc.so.6(+0x45330)                   ← 시그널 트램폴린
```

UCX는 NGC 컨테이너에서 **프로세스 전역 SIGSEGV 핸들러**를 설치합니다.
따라서 어디서 죽든 이 백트레이스가 찍힙니다. 이건 크래시 **지점**이 아니라 **보고자**입니다.

`UCX_TLS` 우회가 안 통한 이유도 이것입니다 — transport를 제한해도 핸들러는 그대로이고,
크래시는 애초에 UCX transport 코드에서 나는 게 아니었습니다.

### 지금까지 탈락한 가설

| 가설 | 결과 |
|---|---|
| 호스트 IB 이상 | IB NIC 전부 ACTIVE / link up |
| `nvidia_peermem` 미로드 | **이미 로드돼 있음** (컨테이너 배너의 "not detected"는 오탐) |
| 컨테이너가 IB를 못 잡음 | `mlx5_0`~`mlx5_15` + `cuda_cpy` + `cuda_ipc` 전부 정상 인식 |
| UCX transport 문제 | `UCX_TLS` 제한해도 동일 — UCX는 신호 보고자일 뿐 |
| 런처 코드 변경 | 원본 zip 대비 실행 경로 변경 없음 |

**남은 유력 후보: B300(sm_103)에 대한 컨테이너의 커널 커버리지.**
현재 쓰는 `-sm90` 태그가 `NVTE_CUDA_ARCHS="89;90;100a;103a"`를 담고 있다는 건
**발행자 문서상의 주장이고, 실제 이미지에서 확인한 적이 없습니다.**

---

## 준비

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull                      # 디버그 변수 전달 기능 (커밋 65bc30d)

NODE=<대상 노드 IP>
IMAGE=donnmyth/mlperf-nvidia:llama2_70b_lora-pyt-sm90
```

---

## STEP 1 — 진짜 백트레이스 확보  ← 최우선

UCX 핸들러를 끄면 Python traceback이나 실제 C++ 스택이 나옵니다.
**이 변수들은 방금 전달 가능해졌습니다** (그 전에는 컨테이너까지 안 갔습니다).

```bash
UCX_HANDLE_ERRORS=none \
UCX_ERROR_SIGNALS= \
TORCH_SHOW_CPP_STACKTRACES=1 \
./scripts/run_single_node.sh --host $NODE --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

전달 확인: 로그의 `[INFO] advanced env forwarded:` 줄에 `UCX_HANDLE_ERRORS`가 보여야 합니다.

**여기서 나오는 스택 전체를 `Errors`에 붙여주세요.** 이게 이번 회차에서 가장 중요합니다.

CUDA 커널에서 죽는 것으로 보이면 launch 지점까지 좁힙니다 (느려지지만 정확해집니다).

```bash
UCX_HANDLE_ERRORS=none CUDA_LAUNCH_BLOCKING=1 TORCH_SHOW_CPP_STACKTRACES=1 \
./scripts/run_single_node.sh --host $NODE --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

---

## STEP 2 — 이미지가 B300(sm_103)을 실제로 지원하는지

계속 미뤄온 확인입니다. 이제 직접 관련이 있습니다.

```bash
ssh $NODE "docker run --rm --gpus all $IMAGE bash -c '
echo \"NVTE_CUDA_ARCHS=\$NVTE_CUDA_ARCHS\"
nvcc --version | tail -2
python -c \"import torch; print(torch.__version__, torch.version.cuda); print(torch.cuda.get_arch_list())\"
'"
```

**판정**

| `get_arch_list()` 결과 | 의미 |
|---|---|
| `sm_100` / `sm_103` 포함 | 이미지는 B300 지원. 원인은 다른 곳 → STEP 1 스택으로 판단 |
| `sm_90`까지만 | **이미지가 B300 미지원.** `-sm90` 태그가 문서상 주장과 다름 → STEP 3 |

TransformerEngine 쪽도 함께 봅니다 (실제 커널이 있는지).

```bash
ssh $NODE "docker run --rm --gpus all $IMAGE bash -c '
so=\$(find / -name \"*.so\" -path \"*transformer_engine*\" 2>/dev/null | head -1)
echo \"== \$so\"
cuobjdump --list-elf \"\$so\" 2>/dev/null | grep -oE \"sm_[0-9]+\" | sort -u | tr \"\\n\" \" \"
'"
```

---

## STEP 3 — Blackwell 전용 태그로 A/B

STEP 2에서 `sm_100`/`sm_103`이 안 보이면 이 이미지로 바꿔서 같은 실행을 합니다.

```bash
UCX_HANDLE_ERRORS=none TORCH_SHOW_CPP_STACKTRACES=1 \
./scripts/run_single_node.sh --host $NODE \
  --docker-image donnmyth/mlperf-nvidia:llama2_70b_lora-pyt \
  --tp 8 --pp 1 --mbs 1 --gbs 128 --max-steps 10
```

접미사 없는 `llama2_70b_lora-pyt`가 발행자 표에서 "upstream default (sm_100/103)"으로
표시된 Blackwell 전용 이미지입니다.

이걸로 통과하면 **B300은 이 태그를 써야 한다**가 확정되고, 런처 기본값을 그렇게 바꾸겠습니다.
(예전에 이 방향으로 바꿨다가 `-sm90`이 더 넓다는 문서 근거로 되돌린 이력이 있습니다 —
실측이 문서를 이깁니다.)

---

## STEP 4 — 결과 회신

`Errors`에 다음을 붙여주세요.

1. **STEP 1의 전체 스택** (가장 중요)
2. STEP 2의 `NVTE_CUDA_ARCHS`, `get_arch_list()`, TE의 `sm_*` 목록
3. STEP 3을 했다면 그 결과 — 통과했는지, 다른 지점에서 죽는지

---

## 이미 확인된 것 (다시 볼 필요 없음)

**런처는 원본 그대로입니다.** `mlperf_run.sh`, `common.sh`는 원본 zip과 바이트 단위로 동일하고,
`mlperf_train_v51.sh`에 추가된 것은 docker tar 폴백과 env 전달 목록뿐입니다.

**컨테이너 실행 인자도 정상입니다.** `--ipc=host`, `--ulimit memlock=-1`,
`--ulimit stack=67108864`, `--network=host`, `--gpus all`, `/dev/infiniband/*` 패스스루를
모두 넘기고 있습니다. 지난 로그들의 SHMEM 경고는 진단용으로 직접 띄운 맨 `docker run`에서
나온 것이라 실제 실행과 무관합니다.

**컨테이너 배너의 "NVIDIA peer memory driver not detected"는 오탐입니다.**
호스트에서 `lsmod`로 `nvidia_peermem` 로드 확인했습니다.

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP와 호스트명이 그대로 들어가 있습니다. 이 저장소는 public이므로
익명화하거나 파일을 지우는 편이 좋습니다. 원하시면 정리해 드리겠습니다.
