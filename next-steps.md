# Next Steps

`Errors`에 올라온 최신 증상에 대해 **지금 실행할 커맨드**만 모아둔 파일입니다.

- 갱신: 2026-08-26 (14회차)
- 상태: **멀티노드 NCCL은 Socket으로 성공.** IB/RDMA 경로만 실패
- 이번 목표: IB를 살리는 것 (Socket은 느려서 벤치마크용으로 못 씁니다)

---

## 1. 직접 찾아내신 것 정리

| 시도 | 결과 |
|---|---|
| IB 기본 | `NET/IB ... status=4 vendor err 81` |
| `NCCL_IB_DISABLE=1` | 여전히 `net_ib.cc` 에러 (아래 참고) |
| `NCCL_NET=Socket` | IPv6 link-local(`fe80::...%bond0`)로 붙으려다 timeout |
| `NCCL_SOCKET_IFNAME='=bond0.3061'` + `NCCL_SOCKET_FAMILY=AF_INET` | **성공. 16 GPU all-reduce 통과** |

Socket 쪽 진단은 정확합니다. NCCL이 `bond0`의 IPv6 link-local을 골랐고,
`=`로 정확 매칭 + `AF_INET` 강제가 맞는 처방이었습니다.

**그 변수들을 스크립트에 반영했습니다.** 직접 고치신 `NCCL_SOCKET_FAMILY`를 포함해
`nccl_probe.sh`와 학습 스크립트 양쪽 allowlist에 넣었습니다. 이제 로컬 수정 없이 됩니다.

---

## 2. IB 실패의 정체 — GDR 의심이 맞습니다

```
NET/IB: Got completion from peer node20<57713> with status=4 opcode=0 len=0 vendor err 81 (Send) hca mlx5_0
```

**`status=4`는 IB verbs의 `IBV_WC_LOC_PROT_ERR` — local protection error입니다.**

이건 네트워크가 안 닿는다는 뜻이 **아닙니다.** 링크는 붙었고, QP도 맺어졌고,
completion까지 돌아왔습니다. 그런데 **로컬 메모리 영역에 HCA가 접근할 권한이 없다**는
겁니다. 즉 등록(registration)된 메모리 키가 실제로는 못 쓰는 상태입니다.

NCCL이 IB로 보내는 버퍼는 **GPU 메모리**입니다. 그 GPU 메모리를 HCA에 등록하는 게
GPUDirect RDMA이고, 그 등록이 겉으로만 성공하고 실제 접근이 막히면 정확히 이 에러가 납니다.

### `ib_write_bw`가 되는 것과 모순되지 않습니다

**`ib_write_bw`는 기본적으로 호스트 메모리를 씁니다.** GPU 메모리가 아닙니다.
그래서 그 테스트는 **파이버·스위치·QP는 정상**임을 증명하지만
**GDR에 대해서는 아무것도 말해주지 않습니다.** 지금 깨진 건 딱 그 부분입니다.

### 등록 경로가 둘입니다

이전 로그에 이 줄이 있었습니다.

```
NCCL INFO DMA-BUF is available on GPU device 0
```

NCCL은 GPU 메모리 등록에 **dma-buf**를 우선 씁니다. `nvidia_peermem`은 그 다음 후보입니다.
드라이버/MOFED 조합에 따라 **dma-buf 등록이 성공한 척하고 실제 접근에서 깨지는** 경우가
있고, 증상이 정확히 `status=4`입니다.

---

## 준비

**`git pull` 필요** (`cb7737e` — `NCCL_DMABUF_ENABLE`, `NCCL_NET_GDR_LEVEL`,
`NCCL_SOCKET_FAMILY` 등 forward 추가).

```bash
cd /mgmt/server/poc-platform/poc-platform-pub
git pull

N1=node19
N2=node20
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell

# 매번 붙일 공통 부분
COMMON="NCCL_NET_PLUGIN=none NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1"
```

---

## 시나리오 — `status=4`가 나올 수 있는 경우 (가능성 순)

`status=4` = `IBV_WC_LOC_PROT_ERR`. **"HCA가 로컬 메모리에 접근할 권한이 없다"** 입니다.
NCCL이 IB로 보내는 버퍼는 GPU 메모리이므로, 아래는 전부 "GPU 메모리를 NIC가 못 읽는다"의
서로 다른 원인들입니다.

| # | 상황 | 확인 | 조치 | 성능 대가 |
|---|---|---|---|---|
| A | dma-buf 등록이 겉으로만 성공 | `NCCL_DMABUF_ENABLE=0`으로 통과 | 그 값 유지 + MOFED/드라이버 갱신 | **없음** |
| B | `nvidia_peermem` 미로드 | `lsmod`에 없음 | `modprobe nvidia_peermem` | 없음 |
| C | GPU BAR1이 작음 | `nvidia-smi -q`의 BAR1 용량 | BIOS: Above 4G Decoding, Resizable BAR | 없음 |
| D | PCIe **ACS** 활성 | `lspci -vvv`에 `SrcValid+` | BIOS에서 ACS 해제 | 없음 |
| E | IOMMU가 P2P 주소 변환 | `dmesg`에 iommu | 커널 파라미터 `iommu=pt` | 없음 |
| F | IB/RoCE HCA 혼용 | `NET/IB` 목록에 RoCE 섞임 | `NCCL_IB_HCA`를 IB만 | 없음 |

**C·D·E는 셋 다 "NIC가 GPU BAR에 직접 DMA를 못 하게 막는" 부류**입니다.
새 서버 세팅에서 가장 흔하게 놓치는 것이 **C(BAR)와 D(ACS)** 입니다.

---

## 준비

```bash
N1=node19
N2=node20
IMG=registry.internal/proxy-docker-registry-1.docker.io/donnmyth/mlperf-nvidia:llama31_8b-pyt-blackwell

COMMON="NCCL_NET_PLUGIN=none NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET \
UCX_HANDLE_ERRORS=none UCX_ERROR_SIGNALS= PYTHONFAULTHANDLER=1"
```

---

## STEP 1 — GDR 껐다 켜서 부류부터 가르기 (30초)

먼저 **"GDR 문제냐 아니냐"** 를 확정합니다. 이게 갈려야 나머지가 의미 있습니다.

```bash
env $COMMON NCCL_NET_GDR_LEVEL=LOC \
./scripts/nccl_probe.sh --hosts $N1,$N2 --image $IMG
```

> `LOC`는 숫자 `0`과 같은 값입니다. NIC와 GPU가 "같은 디바이스"일 때만 GDR을 쓰라는 뜻이라
> 사실상 GDR 해제입니다. 다른 곳에서 제안받으신 것과 동일한 테스트입니다.

| 결과 | 결론 | 다음 |
|---|---|---|
| **통과** | **GDR 확정.** IB·파이버·QP는 정상 | STEP 2 |
| status=4 계속 | GDR 문제 아님 | STEP 5 |

---

## STEP 2 — A인지 B~F인지 가르기 (30초)

GDR은 켠 채로 **등록 경로만** 바꿉니다.

```bash
env $COMMON NCCL_DMABUF_ENABLE=0 \
./scripts/nccl_probe.sh --hosts $N1,$N2 --image $IMG
```

| 결과 | 결론 |
|---|---|
| **통과** | **시나리오 A.** dma-buf만 깨진 것. 이 값 하나로 끝, 성능 손실 없음 |
| status=4 계속 | A 아님 → B~F. STEP 3으로 |

---

## STEP 3 — 호스트 조건 B·C 확인 (ssh, 1분)

**두 노드 다** 봐야 합니다. 한쪽만 어긋나도 실패합니다.

```bash
for h in $N1 $N2; do
  echo "=== $h ==="
  # B: peermem
  ssh $h 'lsmod | grep -E "nvidia_peermem|nv_peer_mem" || echo "  peermem: NOT LOADED"'
  # C: BAR1 — GPU 메모리를 NIC에 노출하는 창. 작으면 등록이 실패합니다
  ssh $h 'nvidia-smi -q | grep -iA3 "BAR1 Memory"| head -8'
done
```

**B 조치**

```bash
ssh <노드> 'modprobe nvidia_peermem && echo nvidia_peermem > /etc/modules-load.d/nvidia-peermem.conf'
```

**C 판단**: B300은 BAR1이 GPU 메모리 크기에 맞먹게 잡혀야 정상입니다.
수백 MB 수준으로 작게 나오면 BIOS에서 **Above 4G Decoding**과 **Resizable BAR**가 꺼진 것입니다.
이건 재부팅이 필요합니다.

---

## STEP 4 — 호스트 조건 D·E 확인 (ssh, 1분)

**D: PCIe ACS.** 켜져 있으면 NIC→GPU 직접 DMA가 루트 컴플렉스로 우회되면서 막힙니다.
GDR을 죽이는 가장 대표적인 원인입니다.

```bash
ssh $N1 'lspci -vvv 2>/dev/null | grep -i ACSCtl | grep -v "SrcValid-" | head'
```

아무것도 안 나오면 ACS 해제 상태(정상)입니다. `SrcValid+`가 보이면 활성입니다.
BIOS에서 끄거나, 부팅 스크립트로 PCIe 스위치마다 해제해야 합니다.

**E: IOMMU.** 켜져 있으면 `iommu=pt`(passthrough)여야 GDR이 삽니다.

```bash
ssh $N1 'cat /proc/cmdline; dmesg | grep -iE "iommu|dmar" | head -5'
```

`intel_iommu=on`만 있고 `iommu=pt`가 없으면 커널 파라미터에 추가 후 재부팅.

---

## STEP 5 — F: HCA 목록 정리 (STEP 1이 통과 못 했을 때)

이전 로그에 **IB와 RoCE가 섞여** 있었습니다.

```
[0]mlx5_0:1/IB/SHARP  [1]mlx5_1:1/IB/SHARP  [2]mlx5_2:1/RoCE  [3]mlx5_3:1/RoCE
[4..11] IB/SHARP      [12]mlx5_12:1/RoCE    [13]mlx5_13:1/RoCE  [14][15] IB/SHARP
```

`mlx5_2, 3, 12, 13`이 RoCE입니다. IB만 남깁니다.

```bash
env $COMMON \
NCCL_IB_HCA='mlx5_0,mlx5_1,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_14,mlx5_15' \
./scripts/nccl_probe.sh --hosts $N1,$N2 --image $IMG
```

---

## STEP 6 — NCCL 없이 GDR만 직접 재는 법 (선택)

`ib_write_bw`를 **GPU 메모리로** 돌리면 NCCL을 빼고 GDR만 시험할 수 있습니다.
(perftest가 CUDA 지원으로 빌드돼 있어야 합니다.)

```bash
# 서버 쪽
ssh $N2 "docker run --rm --gpus all --network=host \
  \$(for d in /dev/infiniband/*; do printf ' --device %s' \$d; done) \
  $IMG ib_write_bw -d mlx5_0 --use_cuda=0"

# 클라이언트 쪽
ssh $N1 "docker run --rm --gpus all --network=host \
  \$(for d in /dev/infiniband/*; do printf ' --device %s' \$d; done) \
  $IMG ib_write_bw -d mlx5_0 --use_cuda=0 $N2"
```

`--use_cuda` 없이 되고 **있이 실패하면 GDR 문제 확정**입니다.
NCCL을 완전히 배제한 증거라 벤더 문의할 때 쓰기 좋습니다.

---

## STEP 5 — Socket은 쓰지 않습니다

Socket 성공은 **진단 결과일 뿐**입니다. "NCCL과 노드 간 경로 자체는 멀쩡하고,
IB의 GPU 메모리 등록만 깨졌다"를 증명한 것이지 대안이 아닙니다.

노드 간 대역폭이 IB 대비 크게 떨어져 멀티노드 스케일링 수치가 의미 없어지므로
**벤치마크에는 쓰지 않습니다.** 실행 스크립트에도 반영하지 않았습니다.

> 확인: `mlperf_train_v51.sh` / `v41.sh` / `run_*.sh` 어디에도 `NCCL_NET=Socket`이나
> `NCCL_SOCKET_IFNAME` 기본값은 없습니다. 값을 설정하는 곳은 B300의
> `NCCL_NET_PLUGIN=none` 하나뿐이고, 나머지 `NCCL_*`는 **직접 줬을 때만 전달**되는
> allowlist 항목입니다. `mlperf_run.sh`의 `NCCL_IB_HCA` / `NCCL_IB_DISABLE=0` /
> `NCCL_SOCKET_IFNAME`은 원본 zip 그대로인 IB 자동 바인딩 코드입니다.

멀티노드 학습은 **IB가 살아난 뒤에** 돌립니다.

---

## STEP 6 — 회신

`Errors`에 붙여주세요.

1. STEP 1 — `NCCL_NET_GDR_LEVEL=LOC` 통과 여부 (**부류를 가르는 것**)
2. STEP 2 — `NCCL_DMABUF_ENABLE=0` 통과 여부
3. STEP 3 — 두 노드의 `nvidia_peermem`, BAR1 용량
4. STEP 4 — ACS, `/proc/cmdline`

1이 갈리면 나머지 범위가 절반으로 줄고, 2가 통과하면 그걸로 끝납니다.

---

## 따로 확인 중인 것 — `NCCL_IB_DISABLE=1`이 안 먹었습니다

2번째 시도에서 `NCCL_IB_DISABLE=1`을 줬는데도 `transport/net_ib.cc` 경고가 계속 나왔습니다.
전달은 됐을 텐데 NCCL이 무시한 모양입니다. `NCCL_NET=Socket`으로는 의도대로 됐으니
당장 막히는 건 없지만, 짚어두겠습니다. STEP 1·2 로그에서 같이 보겠습니다.

---

## 알려진 미해결 — 로그 저장 위치

`log_dir`이 GPU 노드의 `/opt/poc-platform/mlperf_logs_train_v51/...`로 갑니다.
컨테이너 내부 경로가 아니라 **GPU 노드의 실제 경로**입니다 (같은 경로로 bind-mount됨).

`--log-root` 플래그는 이미 있지만 기본값이 스크립트에 박혀 있어 `.env`로는 못 바꿉니다.
`.env`에서 지정 가능하게 고치겠습니다. 그전까지는 이렇게 넘기면 됩니다.

```bash
./scripts/run_multi_node.sh ... --log-root /mgmt/server/poc-platform/mlperf_logs_train_v51
```

---

## 확정된 사실 (기록용)

| 항목 | 결과 |
|---|---|
| 단일 노드 학습 8장 | **통과** |
| 멀티노드 NCCL (Socket) | **통과 — 16 GPU all-reduce** |
| 멀티노드 NCCL (IB) | 실패 — `status=4` local protection error |
| `ib_write_bw` | 통과. 단 **호스트 메모리 기준**이라 GDR 검증 아님 |
| 이전 SIGSEGV 원인 | HPC-X `libnccl-net.so` ↔ NCCL 2.28.3 불일치 |
| 그 해결 | `NCCL_NET_PLUGIN=none` (B300 기본값, `489dc11`) |
| 드라이버 | 580.173.02 (r580) — 정상 |
| 호스트 NCCL / HPC-X | 컨테이너와 무관 |
