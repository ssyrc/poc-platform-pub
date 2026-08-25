# Release Notes

현재 버전: **v6.67**

버전별로 나뉘어 있던 `RELEASE_NOTES_v*.md` 84개 파일을 이 문서 하나로 통합했습니다.
개별 파일의 원본 전문은 git 히스토리(`git show 32fd75b`)에서 확인할 수 있습니다.

---

## v6.67 (latest)

### MLPerf bare-metal multi-node RDMA auto-binding

- MLPerf bare-metal multi-node Training에 host별 GPU↔NIC 자동 탐지를 추가했습니다.
- 선택된 GPU에 대해 `nvidia-smi topo -m`을 파싱하고 `PIX → PXB → PHB → NODE → SYS` affinity 우선순위로 NIC을 선택합니다.
- 선택된 NIC은 `mlx5_0` 형태의 HCA 이름으로 변환해 `NCCL_IB_HCA`로 전달합니다.
- `ibdev2netdev`로 HCA를 netdev에 매핑하고, UP 상태이면서 global IP를 가진 인터페이스만 `NCCL_SOCKET_IFNAME`에 사용합니다.
- `MASTER_ADDR`가 지정되지 않으면 rank 0이 탐지한 compute-net IP를 사용합니다.
- 자동 탐지는 host마다 독립적으로 수행되므로 서버 간 NIC/HCA 번호가 일치할 필요가 없습니다.
- `NCCL_IB_HCA`, `NCCL_SOCKET_IFNAME`, `MASTER_ADDR`를 명시하면 자동 선택보다 우선합니다.
- Training v4.1/v5.1 모두 multi-node/NCCL 변수를 SSH와 Docker로 전달하고, `/dev/infiniband/*` device passthrough를 자동 적용합니다.

---

## 주요 변경 이력 요약

### v6.63 ~ v6.66 — 공개 저장소 준비

- site-specific 보안 정보(Warewulf/Kubernetes endpoint, registry credential, Docker proxy 설정, 사용자별 데이터 경로)를 코드에서 분리해 `.env` 기반 설정으로 전환. `.env`는 Git 제외, `.env.example`만 제공.
- Docker registry password를 소스/원격 커맨드에서 제거하고 controller `.env`에서 읽어 SSH stdin으로 전달.
- DockerHub 이미지의 local tag 기준을 `${DOCKER_HUB_IMAGE_PREFIX}`로 복구하고, `docker pull`만 `${DOCKER_HUB_PULL_PREFIX}` 경로로 시도 후 local tag로 재태깅.

### v6.57 ~ v6.62 — Dashboard 영속성 / 브랜딩

- `/api/dashboard` 백엔드 저장(`.poc_platform_state/dashboard.json`)을 추가해 pinned data가 브라우저 localStorage를 넘어 버전 업그레이드 후에도 유지.
- pin id를 `run_id + host` 기반 stable id로 변경하고 localStorage↔backend 병합 시 semantic dedupe 적용. 기존 중복 데이터도 로딩 시 자동 정리.
- Dashboard 최근 실행에 `대시보드 전체 반영` 버튼 추가, Pinned Data/최근 실행 타이포그래피 정리.
- 브라우저 탭 favicon(SVG/PNG/ICO) 추가.
- `frontend/index.html`의 중복 inline React app으로 인한 blank screen 수정.

### v6.49 ~ v6.56 — Dashboard 축/시리즈 정리, MLPerf Inference 컨테이너 안정화

- version/model/environment 필터가 `all`일 때 chart series key를 자동 확장해 무관한 run이 한 선으로 이어지지 않도록 수정. legend는 `A100 / v4.1 / Llama2_70b_lora / Bare Metal` 형태의 value-only label로 정리.
- 숫자 X축에 nice min/max와 정수 tick 적용, x/groups 선택지에서 result metric 제외.
- MLPerf Inference v5.1/v6.0 컨테이너를 root로 기동한 뒤 `setpriv`/`runuser`로 non-root 전환, NVIDIA device/socket gid를 `--group-add`로 전달.
- 컨테이너에 host Docker CLI/소켓을 마운트하고 platform data root를 `/data`로 bind-mount(`DATA_DIR`, `MLPERF_DATA_DIR`).
- vLLM: `--group 0` 버그(Bash 예약변수 `GROUPS`) 수정, health polling이 기동 중 connection-refused로 조기 종료되지 않도록 수정, bench 인자를 마운트 스크립트로 분리해 Docker가 `--dataset-name`을 볼륨으로 오인하지 않도록 수정.

### v6.43 ~ v6.48 — Hydra override / 실행 수명주기

- Training v5.1의 struct-config 실패를 피하기 위해 플랫폼 주입 `trainer.*`, `model.*`, `exp_manager.*`, `ckpt_root`, `data_root` override를 `++` 형태로 생성. 사용자 지정 `+`/`++`/`~`는 보존.
- 플랫폼 종료 시 backend 소유 launcher 프로세스를 정리하고 active run을 `stopped`로 영속화.
- MLPerf Inference v6.0의 FP4 모델 디렉터리를 플랫폼 고정 경로로 변경하고 부재 시 validation 실패 대신 warning 처리.

### v6.36 ~ v6.42 — Docker bootstrap, Precision, run history

- bare-metal 실행 전 Docker 미설치 서버에 대해 오프라인 RPM 설치, daemon/proxy 설정, 내부 registry 로그인을 자동화.
- 이미지 확보 순서를 fallback tar `docker load` 우선 → 실패 시 proxy 설정 갱신 후 `docker pull` 재시도로 변경.
- Training Precision UI를 도입하고 NeMo/Lightning 허용값으로 정규화(FP32/FP64 제거, legacy 값은 `bf16-mixed`/`16-mixed`로 보정).
- multi-node UI에서 `NUM_GPUS`를 제거하고 `GPUS_PER_NODE`로 통일, host별 `CUDA_VISIBLE_DEVICES` 지정 지원.
- single-node fan-out에서 한 host의 fatal error가 다른 host launcher를 종료시키지 않도록 분리하고, 로그를 host별로 필터링.

### v6.29 ~ v6.35 — GPU type 자동 탐지, single/multi-node 모드

- 실행 시작 시 backend가 host별 GPU type을 자동 탐지(NVIDIA `nvidia-smi`, AMD `rocm-smi` best-effort)하고 run metadata를 보정. `/api/hosts/{host}/gpu_type` 추가.
- Training/Inference에 Single-node / Multi-node 실행 모드 추가. multi-node는 torchrun `nnodes`/`node_rank` 기반 launcher 사용.
- PD Disaggregation 세부 파라미터를 instance 단위(hostname, NUM_GPUS, TP, CUDA_VISIBLE_DEVICES, port, proxy port, extra docker args)로 재구성.
- Run History / Dashboard 최근 실행에 기록 삭제 기능과 삭제 확인 모달 추가.

### v6.20 ~ v6.28 — 로그 파싱, 이미지 fallback, Pinned Data

- MLPerf Training v4.1의 carriage-return progress bar와 embedded `:::MLLOG`가 섞인 stdout을 안정적으로 파싱(`reduced_train_loss`, `global_step`, `consumed_samples` → `train_loss` 정규화). 공식 MLLOG 값이 tqdm repaint로 덮이지 않도록 보호.
- subprocess stdout을 chunk 단위로 읽고 `\n`/`\r` 모두에서 분할해 실시간 로그 스트리밍 개선, ANSI escape 제거.
- MLPerf/vLLM/llm-d 이미지 pull 실패 시 `data/dockerimgs` 하위 tar에서 `docker load` fallback 추가. GH200(aarch64 Grace) 전용 이미지 경로 지원.
- Pinned Data 테이블 열 순서를 groups 선택값 기준으로 동적 재정렬하고, chart point ↔ 테이블 행 클릭 하이라이트 연동.

### v6.10 ~ v6.19 — Dashboard 필터 체계, batch size 파라미터

- Dashboard 필터를 `category → 테스트 종류 → version/model/환경/mode` 구조로 재정렬하고, pin 저장 시 suite/test_kind/version/model/env/mode metadata를 명시 저장. legacy pin은 run history에서 복구.
- Training GBS 기본값 128, MBS 입력 추가, 검증식을 `GBS % (MBS × DP) == 0`으로 변경.
- `trainer.log_every_n_steps=1`, `enable_progress_bar=true`, `PYTHONUNBUFFERED=1`을 기본 적용해 step 로그 스트리밍 지연 해소.
- GPU 모니터링 timeline 이동 UI를 Recharts Brush에서 커스텀 슬라이더로 교체.
- FAILED/ERROR/PARTIAL run은 metric 대신 error message를 우선 표시하되 수집된 GPU 그래프는 유지.

### v6.0 ~ v6.9 — 테스트 화면 재구성

- 테스트 화면을 `설정&실행 / 실시간 모니터링 / 로그 확인 / 결과 확인 / Run History` 5개 구역으로 재구성. 브랜딩을 Server PoC Platform으로 변경.
- bare-metal 실행 시 `nvidia-smi` 기반으로 사용 가능한 GPU를 자동 선택해 `MLPERF_CUDA_VISIBLE_DEVICES` / `--gpu-map`으로 전달하고, 노드 카드에 free/total GPU 수를 표시.
- 세부 파라미터에서 host별 `CUDA_VISIBLE_DEVICES` 직접 지정 지원.
- 실행 history를 `.platform_state/runs.json`에 영속화해 backend 재시작 후에도 유지.
- 결과 metric에서 메타 필드를 제거하고 accuracy/loss/throughput/latency/TTFT/TPOT/duration 계열만 표시. 실패 시 CUDA OOM, NCCL error, RuntimeError 등 핵심 에러를 추출해 표시.
- TP, vLLM serve port(9001) 등 기본값을 GPU 노드 설정 기준으로 자동 동기화.

### v3.5.6 ~ v3.5.26 — 플랫폼 리브랜딩 및 클러스터 관리

- 배포 패키지를 `mlperf-platform-*`에서 `poc-platform-*`으로 변경하고 기본 경로를 `POC_PLATFORM_ROOT` 레이아웃(`files/`, `data/`)으로 재정의.
- 테스트 클러스터 관리 탭 신설: Warewulf 노드 추가/전원 제어(`on`/`off`/`cycle`/`reset`), 노드 부팅 확인(ping/SSH), 노드 상세 정보 파싱 뷰.
- Kubernetes 모니터링을 control-plane SSH 원격 `kubectl` 기반으로 전환(`cm_kubectl` helper), pod/container/workload 상태 모니터링 추가.
- Warewulf API 인증을 Bearer token / Basic auth / raw Authorization header로 지원하고 실패 시 진단 정보를 UI에 표시.
- Training/Inference 탭을 MLPerf / vLLM 서브탭과 K8s / Bare Metal 런타임 선택 구조로 정리.
- Dashboard 초기 UI 구성: Fields → Axis/Groups → Chart 흐름, GPU Type 필터, Pinned Data 테이블.

---

## 검증 커맨드

```bash
python3 -m py_compile backend/*.py
bash -n start_platform.sh scripts/*.sh scripts/*/*.sh
# frontend/app.jsx 및 frontend/index.html inline Babel transform 확인
```
