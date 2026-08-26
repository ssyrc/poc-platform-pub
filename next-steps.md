# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.
`Errors`가 갱신되면 이 파일도 갱신됩니다.

- 갱신: 2026-08-26
- 대상 증상: training v5.1 단일노드 실행 중 UCX segfault

---

## 상황

단일노드 실행이 **분산 초기화 직전까지 정상 진행**된 뒤 컨테이너 안에서 죽었습니다.

```
Caught signal 11 (Segmentation fault: address not mapped to object at address (nil))
 0  /opt/hpcx/ucx/lib/libucs.so.0(ucs_handle_error+0x2e4)
```

MLLOG init, `GPU available: True`, NeMo experiment 디렉터리 생성, `global_batch_size: 128`까지
찍혔으므로 런처가 넘긴 인자·경로·이미지는 모두 정상입니다. HPC-X의 UCX에서 터졌습니다.

**`NCCL_IB_DISABLE=1`로는 회피되지 않습니다.** 그 변수는 NCCL에만 적용되고 UCX는 별개 스택이라
계속 IB transport를 잡으려 합니다.

`mlperf_train_v51.sh:1123`이 호스트에 `/dev/infiniband`가 있으면 전부 컨테이너에 넘깁니다.
단일노드는 IB가 필요 없는데도 UCX가 그 장치를 열다 죽는 정황입니다.

---

## 준비

아래 커맨드에서 쓸 노드 주소를 먼저 지정하세요.

```bash
NODE=<대상 노드 IP 또는 호스트명>
IMAGE=donnmyth/mlperf-nvidia:llama2_70b_lora-pyt-sm90
```

---

## STEP 1 — 노드의 IB 스택 상태

호스트 IB가 정상인지부터 봅니다. 여기서 깨져 있으면 스크립트로 우회할 문제가 아닙니다.

```bash
ssh $NODE 'ibv_devinfo'
ssh $NODE 'ibstat'
ssh $NODE 'ls -l /dev/infiniband/'
ssh $NODE 'ibdev2netdev'
```

**판정**

| 결과 | 의미 |
|---|---|
| `ibv_devinfo`가 segfault / 아무것도 출력 안 함 | 호스트 IB 스택 문제 → STEP 3으로 우회 후 인프라 담당자에게 |
| 포트가 `PORT_DOWN` / `INIT` | 케이블·서브넷 매니저 문제 → 단일노드는 STEP 3으로 진행 가능 |
| 포트가 `PORT_ACTIVE` 인데도 컨테이너에서 죽음 | 이미지 ↔ 노드 IB 조합 문제 → STEP 2로 |
| `/dev/infiniband/` 자체가 없음 | IB 미구성. 그러면 segfault 원인은 다른 곳 → STEP 2 결과 필요 |

---

## STEP 2 — 컨테이너 안에서 UCX가 무엇을 잡는지

호스트가 아니라 컨테이너 안에서 재현되는지 확인합니다. 벤치마크 없이 UCX만 건드립니다.

```bash
ssh $NODE "docker run --rm --gpus all \
  \$(for d in /dev/infiniband/*; do echo --device \$d:\$d; done) \
  $IMAGE bash -c 'ucx_info -d 2>&1 | head -40'"
```

여기서도 segfault면 **이미지와 노드 IB 조합 문제로 확정**입니다.

IB 장치를 빼고 같은 것을 실행해 비교합니다. 이쪽이 정상이면 원인이 IB 패스스루로 좁혀집니다.

```bash
ssh $NODE "docker run --rm --gpus all $IMAGE bash -c 'ucx_info -d 2>&1 | head -40'"
```

---

## STEP 3 — 공유메모리 전용으로 우회 시도

단일노드는 IB가 필요 없으므로 UCX를 shared memory + CUDA IPC로 제한하면 넘어갈 수 있습니다.
아래는 **스크립트를 거치지 않고** docker를 직접 띄워 격리 확인하는 방법입니다.

```bash
ssh $NODE "docker run --rm --gpus all \
  -e UCX_TLS=sm,self,cuda_copy,cuda_ipc \
  -e UCX_NET_DEVICES=all \
  $IMAGE bash -c 'ucx_info -d 2>&1 | head -20'"
```

이게 통과하면 `UCX_TLS`를 컨테이너로 전달하도록 런처를 수정하면 됩니다.
현재는 `build_env_exports` 허용목록에 없어서 전달되지 않습니다 — **알려주시면 넣겠습니다.**

---

## STEP 4 — 결과 회신

STEP 1~3 출력을 `Errors`에 붙여넣어 주세요. 특히 다음 세 가지가 판정에 필요합니다.

1. `ibv_devinfo`의 `state` 줄 (`PORT_ACTIVE` / `PORT_DOWN` / 크래시 여부)
2. STEP 2의 두 실행 결과 차이 (IB 장치 있을 때 vs 없을 때)
3. STEP 3이 통과했는지

이 결과에 따라 다음 중 하나로 진행합니다.

- IB 장치 유무가 갈림 → 단일노드에서 `/dev/infiniband` 패스스루를 건너뛰는 `--no-ib` 옵션 추가
- `UCX_TLS`로 우회됨 → UCX 계열 변수를 허용목록에 추가
- 컨테이너 무관하게 호스트에서 크래시 → 스크립트 수정 대상 아님. 노드 IB 재구성 필요

---

## 이미 확인된 것 (다시 볼 필요 없음)

원본 zip 대비 런처 변경분을 git으로 대조했습니다.

| 파일 | 원본 대비 |
|---|---|
| `scripts/mlperf_run.sh` | 변경 없음 |
| `scripts/common.sh` | 변경 없음 |
| `scripts/mlperf_train_v51.sh` | +23줄 — 전부 docker tar 폴백과 주석 |
| `scripts/mlperf_train_v41.sh` | +38/-4 — B300 게이팅과 tar 폴백 |

v5.1 실행 경로에서 추가된 기능은 tar 폴백 하나뿐이고, 기본 경로에 tar가 없을 때만 동작합니다.
이번 crash와 무관합니다.

---

## 참고 — 정리해두면 좋은 것

`Errors` 파일에 노드 IP와 호스트명이 그대로 들어가 있습니다. 이 저장소는 public이므로
익명화하거나 파일을 지우는 편이 좋습니다. 원하시면 정리해 드리겠습니다.
