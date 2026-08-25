이 라운드는 poc-platform-dev(8101)에는 반영/테스트 중이나 아직 git commit 안 함 — 사용자 테스트 확인 후
커밋/GitHub push 예정. **이 파일(HISTORY.md)은 사용자 요청에 따라 앞으로 매 라운드 작업 후
자동으로(요청 없이도) 갱신해야 함 — 커밋 여부와 무관하게 작업이 끝날 때마다 반영.**

### 2026-08-13 — 폐쇄망 dev 배포 폴더명을 `poc-platform-dev`로 고정

- 사용자가 폐쇄망 서버에서 dev/디버그용 배포 폴더명을 버전 스냅샷 이름(예: `poc-platform-v6.64`)
  대신 고정된 `poc-platform-dev`로 변경함. 이후 dev 인스턴스(보통 8101)는 항상
  `/opt/poc-platform/poc-platform-dev/`를 가리킴 — 버전이 올라가도 폴더명을
  다시 바꿀 필요 없음.
- 위 문서 앞부분의 "배포 토폴로지", `.poc_platform_state/` 공유 설명, `poc-platform-dev.service`
  systemd 유닛(README.md)도 이 폴더명으로 갱신함. 단, 위쪽에 남아있는 날짜 있는 과거 라운드 로그
  (2026-08-11~12, `poc-platform-v6.64` 언급 부분)는 그 시점의 실제 폴더명을 반영한 기록이므로
  의도적으로 그대로 둠 — 앞으로 dev 폴더를 가리킬 때는 새 이름 `poc-platform-dev`를 사용할 것.

### 2026-08-13 두 번째 라운드 — CAGR 라인 시작점 수정 + dev venv 장애 진단/수정 + dev state 분리

- **가속기별 성능 탭 CAGR 점선이 "From GPU"부터 나타나도록 수정.** 기존엔 `cagrLines`
  (frontend/index.html, `useMemo`)의 `for` 루프가 `rangeEndYear = Math.max(first.release_year,
  last.release_year)`부터 시작해서, 사용자가 from/to 두 GPU를 고르면 점선이 **to 연도부터만**
  그려지고 from~to 구간(실제값이 있는 구간)에는 추세선이 안 보였음. `rangeEndYear`를
  `rangeStartYear = anchor.release_year`(항상 연도가 이른 쪽, from GPU)로 바꿔서 from 연도부터
  미래까지 쭉 이어지는 추세선으로 변경. 계산 로직(`cagr`, `anchor`) 자체는 그대로, 점을 찍는
  시작 연도만 변경.
- **poc-platform-dev(8101)가 계속 재시작 루프에 빠지는 문제 진단/수정.**
  `journalctl -u poc-platform-dev.service`에 `status=127`, `.poc_platform.log`에
  `start_platform.sh: line 285/330: python: command not found`가 반복 기록됨. 원인:
  `poc-platform-dev/.venv/bin/python`이 깨져 있었음(실행 불가) — `start_platform.sh`의 기존
  venv 재사용 로직(`if [[ -d "$VENV" && -x "$VENV/bin/python" ]]`)이 "venv 폴더는 있지만
  bin/python이 실행 불가"인 경우를 전혀 감지하지 못하고 그냥 통과시켜 버리는 버그가 있었음
  (조건이 애초에 false이면 RECREATE도 안 켜지고 재생성 로직도 안 타서 깨진 상태로 그대로 실행).
  `start_platform.sh`를 `if [[ -d "$VENV" ]]; then if -x && py_version_ok then 재사용 else
  RECREATE=1 fi; fi` 구조로 수정해, venv가 있어도 bin/python이 없거나 실행 불가하면 항상
  자동으로 지우고 재생성하도록 함. 즉시 조치로 사용자가 서버에서 직접 `rm -rf .venv &&
  systemctl restart poc-platform-dev`도 실행.
- **dev와 latest가 `.poc_platform_state/`를 공유하는 문제 — 분리.** `backend/state.py`는 이미
  `POC_PLATFORM_STATE_DIR` 환경변수를 지원하고 있었으므로(코드 변경 불필요), README.md의
  `poc-platform-dev.service` 유닛 예시에 `Environment="POC_PLATFORM_STATE_DIR=/opt/pocuser/
  01_BMT/poc-platform/.poc_platform_dev_state"`를 추가. 폐쇄망 마운트(`/mnt/share/...`)에서
  `rsync -a .poc_platform_state/ .poc_platform_dev_state/`로 기존 상태를 시드 복사해둠(dev가
  빈 데이터로 시작하지 않도록). 사용자가 서버에서 실제 systemd 유닛 파일에 이 줄을 추가하고
  `daemon-reload` + 재시작해야 실제로 적용됨(이 세션은 `/etc/systemd/system/`을 직접 건드릴 수
  없고 `/mnt/share/...` 마운트를 통한 파일시스템 접근만 가능).

### 2026-08-13 세 번째 라운드 — venv 재발/진짜 원인 발견: `module load python-3.13.0` 필요

- 위 두 번째 라운드의 venv 재사용-감지 버그 수정은 배포했지만, 실제로 dev를 재기동하니
  여전히 실패(`exit code 1`, `.../bin/activate: No such file or directory`)했음. `.venv/bin/`을
  확인해보니 `python`/`pip` 심링크류는 만들어졌는데 `bin/activate`가 애초에 생성되지 않은 채로
  끝나 있었음 — venv 생성(`python3.13 -m venv`) 자체가 매번 처음부터 다시 시작되지만 끝까지
  완료되지 못하고 있던 것으로 보였음(당시엔 systemd `RestartSec=10`이 venv 생성을 매번 죽이는
  것으로 추정하고 "systemd 끄고 foreground로 한 번 완주시켜라"를 제안함).
- **사용자가 실제로 확인한 진짜 원인**: 서버에서 `.venv` 지운 뒤 `module load python-3.13.0`을
  실행하고 `PORT=8101 ./start_platform.sh`로 돌리면 정상적으로 뜸. 즉 `/apps/python/Python-3.13.0`
  툴체인은 **environment-modules의 `python-3.13.0` module이 로드된 셸 환경**(예: `LD_LIBRARY_PATH`
  등)이 있어야 venv/pip 생성이 온전히 끝나고, 없으면 venv가 조용히 반쪽만 만들어짐(`bin/activate`
  누락). systemd의 `ExecStart=/usr/bin/env bash .../start_platform.sh`는 로그인/인터랙티브 셸이
  아니라서 `~/.bashrc`나 `/etc/profile.d/modules.sh`가 자동으로 로드되지 않아 이 문제가 systemd
  경유일 때만(수동 인터랙티브 셸에서는 이미 module이 로드돼 있어서) 터졌던 것.
- **수정**: `start_platform.sh`에 "step 0.5"로 `MLPERF_ENV_MODULE`(기본값 `python-3.13.0`) 자동
  로드 단계를 추가. `command -v module`이 없으면 `/usr/share/Modules/init/bash`,
  `/usr/share/lmod/lmod/init/bash`, `/etc/profile.d/modules.sh` 중 존재하는 걸 source해서 `module`
  함수를 확보한 뒤 `module load "$MLPERF_ENV_MODULE"` 실행(실패해도 워닝만 찍고 계속 진행 —
  module 시스템이 없는 로컬 개발 머신에서도 안전). `MLPERF_ENV_MODULE=""`로 끄거나 다른 module명
  지정 가능. README.md의 두 systemd 유닛 예시(`poc-platform.service`, `poc-platform-dev.service`)에도
  `Environment="MLPERF_ENV_MODULE=python-3.13.0"` 명시적으로 추가.
- 이 스크립트는 latest/dev가 공유하는 유일한 진입점이라 한 번 고치면 양쪽에 다 적용됨. dev에
  rsync 배포 완료.

### 2026-08-13 네 번째 라운드 — 테스트 탭 "GPU 노드 설정"의 hostname 필드 라벨을 "IP/hostname"으로 변경

- Training/Inference(MLPerf, vLLM/PD/llm-d) 3개 탭의 "설정&실행" → "GPU 노드 설정" 구역은 전부
  하나의 공유 컴포넌트 `NodeAdder`(frontend/index.html:12139)를 쓰고, 그 안의 호스트 입력
  textarea 라벨도 `<BenchField label="hostname">`(12316) 한 곳뿐 — 이걸 `"IP/hostname"`으로,
  placeholder도 `"gpu-node01 gpu-node02"` → `"gpu-node01 gpu-node02 또는 192.0.2.41"`로 바꿔서 IP 입력이
  가능하다는 걸 UI에서 바로 알 수 있게 함(기능적으로는 원래부터 IP를 받아들이고 있었음 — 이전
  라운드에서 확인, 코드 검증/백엔드/스크립트 어디에도 hostname 형식 강제가 없고 IPv4는 통과하는
  정규식만 있었음). 다섯 군데 렌더 위치(Training nodes / Inference nodes(MLPerf) / Inference
  nodes(vLLM) / Prefill nodes / Decode nodes) 모두 이 한 컴포넌트를 재사용하므로 한 줄 수정으로
  전부 반영됨.
- 건드리지 않은 것: (1) "테스트 클러스터 관리" 탭의 Warewulf 노드 추가 폼 `hostname`
  필드(index.html:11633) — 신규 베어메탈 노드 등록용으로 바로 옆에 별도 `ipaddr` 필드가 있는
  용도가 다른 필드라 이번 요청 범위 밖. (2) `LlmdConfig`의 인스턴스별 세부설정(prefill/decode
  instance 카드) 안에 있는 `<Field label="hostname">` 드롭다운(12946) — 이미 추가된 노드 목록
  중에서 고르는 `<select>`라 자유 텍스트 입력이 아니고, "GPU 노드 설정" 섹션 자체도 아님.
- dev에 rsync 배포 완료. 아직 git commit 안 함(사용자가 dev에서 확인 후 운영 포트로 배포하는
  흐름을 밟는 중).

### 2026-08-13 다섯 번째 라운드 — 비용 분석 탭 환율 입력 스피너 제거 + vLLM bench 확인 질의 응답

- **비용 분석 탭 맨 위 "₩/USD 환율" `<input type="number">`(index.html:8620)의 브라우저 기본
  업/다운 스피너 버튼 제거.** 이미 `.gpu-stepper input`에 있던 것과 같은 패턴으로 `fx-rate-input`
  className을 추가하고, `.fx-rate-input::-webkit-outer/inner-spin-button { -webkit-appearance:none }`
  + `.fx-rate-input[type=number] { -moz-appearance:textfield }` CSS를 style 블록에 추가(507번째 줄
  근처). input type은 그대로 number라 직접 타이핑/화살표키 입력은 계속 가능, 스피너 UI만 숨김.
  다른 number input 13개는 건드리지 않음(요청 범위가 이 필드 하나였음).
- **질의 응답(코드 변경 없음)**: "vLLM 테스트에서 bare metal, single/multi-node 모두 guidellm으로
  부하테스트하는지" 확인 요청 → `scripts/vllm/vllm_bench.sh`(일반 vLLM 서빙, `--hosts`로 Ray
  클러스터 구성, host 1개면 head만/N개면 head+worker) 와 `scripts/pd/pd_serve_vllm.sh`(PD 분리
  서빙, proxy 앞단) 둘 다 최종적으로 `GCMD=(guidellm run --backend ... --profile ... --data ...
  --output kind=json,path=.../guidellm.json)`을 실행해 부하를 생성함(vllm_bench.sh:930,
  pd_serve_vllm.sh:1220). 노드 수(single/multi)는 Ray 클러스터 구성 단계에만 영향을 주고, bench
  단계는 노드 수와 무관하게 항상 guidellm 경유로 동일 — 확인 완료.
- dev에 rsync 배포 완료.

### 2026-08-13 열네 번째 라운드 — NodeAdder 폭 불일치 실제 원인(PD 2단 레이아웃 오버플로) 수정 + 입력창 시각적 강조

- **실제 원인**: 지난 라운드에서 `.node-input-grid`/`.gpu-qty-with-probe`의 `minmax()` 최소폭을
  크게 올렸는데(`220px+320px=540px`, `150px+200px=350px`), 이게 Inference 탭 vLLM 서브탭의
  PD(Prefill/Decode) 모드처럼 **NodeAdder 두 개가 나란히 배치되는 좁은 레이아웃**
  (`.config-main-grid`가 2컬럼 `repeat(2,minmax(0,1fr))`로 카드 폭을 절반으로 쪼개고, 그 안에서
  `.pd-node-grid`가 다시 2컬럼으로 Prefill/Decode를 나란히 배치 — 실사용 폭이 카드당 ~350~400px
  수준까지 좁아짐)에서는 최소폭 합이 사용 가능한 폭을 넘어서 그리드가 넘쳐버림(overflow) —
  그 결과 hostname/GPU수량/free상태 세 요소의 합이 아래 "+ 노드 추가" 버튼(컨테이너 폭에 정확히
  맞춰 100%)보다 넓어져 정렬이 깨졌던 것. Training/Inference-MLPerf/vLLM(단일 NodeAdder, 카드
  전체폭 ~780~790px)에서는 여유가 있어 안 보였을 수 있음.
- **수정**: 기본값은 `minmax(200px,.65fr) minmax(240px,1fr)`(node-input-grid)/
  `140px minmax(160px,1fr)`(gpu-qty-with-probe)로 적당히 넉넉하게 유지하고, **PD 2단 레이아웃
  전용으로 더 작은 최소폭 오버라이드**를 추가: `.pd-node-section .node-input-grid { grid-template-columns:
  minmax(130px,.6fr) minmax(160px,1fr); }`, `.pd-node-section .gpu-qty-with-probe { grid-template-columns:
  110px minmax(110px,1fr); }` — CSS 특이성상 `.pd-node-section` 하위에서만 이 좁은 값이 적용되고,
  나머지 넓은 컨테이너에서는 기본값이 유지되어 두 상황 모두에서 위 세 요소의 합이 정확히
  "+ 노드 추가" 버튼 폭과 일치하게 됨(둘 다 `fr` 기반이라 오버플로만 없으면 항상 100% 일치).
- **IP/hostname·GPU 수량 입력창을 더 눈에 띄게**: 사용자 피드백("너무 흐릿하게 보이고 입력해야
  한다는 생각이 안 듦") 반영. `.node-host-input`(textarea)과 `.gpu-stepper`(GPU 수량 stepper)에
  기본 상태에서도 보이는 보라색 계열 테두리(`#6a63a0`, 1.5px)+연한 인셋 글로우+살짝 밝은 배경
  (`#181630`, 카드 배경보다 밝음)을 추가. `.gpu-stepper`는 다른 화면(TP/PP/GBS 등 하이퍼파라미터
  스테퍼)에서도 같은 클래스를 공유해서 그 화면들까지 바뀌면 안 되므로, NodeAdder 전용으로
  `node-gpu-stepper` 클래스를 별도로 얹어 스코프를 좁힘 — 다른 곳의 `.gpu-stepper`는 그대로 둠.
  두 필드의 라벨("IP/hostname", "GPU 수량")도 `BenchField`의 `label` prop에 일반 문자열 대신
  진한 흰색 굵은 글씨 `<span>`을 넘겨서 더 잘 보이게 함(다른 `BenchField` 사용처에는 영향 없음 —
  `label` prop이 원래도 React 노드를 받을 수 있는 구조라 이 두 곳만 변경).
- dev에 rsync 배포 완료.

### 2026-08-13 열세 번째 라운드 — NodeAdder(모든 테스트 탭 "GPU 노드 설정") placeholder 갱신 + 입력창들 가로로 넓힘

- **placeholder 예시 IP 변경**: `"gpu-node01 gpu-node02 또는 192.0.2.41"` → `"gpu-node01 gpu-node02 또는
  192.0.2.41"`(`frontend/index.html:12401`). 파일 내 이 문자열이 쓰이는 곳은 이 한 곳뿐이라
  (grep 확인) NodeAdder 공유 컴포넌트 특성상 Training/Inference(MLPerf/vLLM/PD/llm-d) 5곳 전부에
  자동 반영.
- **IP/hostname textarea·GPU 수량 입력·GPU free 상태 표시 가로 폭 확장**: `.node-input-grid`
  (구분: hostname 컬럼 / GPU 수량 컬럼)를 `minmax(150px,.52fr) minmax(280px,1fr)` →
  `minmax(220px,.7fr) minmax(320px,1fr)`로, `.gpu-qty-with-probe`(GPU 수량 컬럼 내부: 스테퍼 /
  free 상태칩)를 `112px minmax(168px,1fr)` → `150px minmax(200px,1fr)`로 넓힘. 둘 다 `fr` 단위라
  이 행(hostname 입력 + GPU 수량 입력 + free 상태)의 전체 폭은 원래도 부모 컨테이너 100%를
  채우고 있었고(아래 "+ 노드 추가" 버튼과 같은 `.node-bottom-controls`(flex-column, 기본
  align-items:stretch)의 형제 요소라 폭이 이미 서로 같았음), 이번엔 명시적으로 `width:100%`도
  추가해서 이 관계를 CSS 레벨에서 확실히 고정 — 앞으로 다른 수정으로 어긋나지 않게.
- dev에 rsync 배포 완료.

### 2026-08-13 열두 번째 라운드 — 숫자 입력 스피너 전역 제거(규칙으로 고정) + TCO 헤더 레이아웃 재배치

- **숫자 입력 스피너를 전역으로 제거하고, 이제부터 절대 다시 넣지 않기로 함.** GPU 모델별 TCO
  셀 수정 모드의 `<input type="number">`에도 스피너가 뜨는 문제 발견 — 지난 라운드들에서
  `.fx-rate-input`, `.gpu-stepper input` 처럼 필드별로 클래스를 붙여 스피너를 숨겨왔는데, 매번
  새 숫자 입력을 추가할 때마다 또 빠뜨릴 수 있는 방식이었음. 그 두 개의 필드별 규칙을 삭제하고,
  **`input[type=number]` 전체에 적용되는 전역 규칙**으로 교체(`frontend/index.html` 최상단 style
  블록, `::-webkit-outer/inner-spin-button { -webkit-appearance:none }` + `-moz-appearance:textfield`).
  주석으로 "앞으로 이 스피너를 다시 넣지 말 것 / 필드별로 다시 스코프하지 말 것"을 명시해둠 —
  앞으로 숫자 입력을 새로 추가해도 자동으로 스피너 없이 나옴.
- **비용 분석 탭 레이아웃 재배치.** 맨 위 독립 카드로 떠 있던 "₩/USD 환율" 입력을 없애고,
  "GPU 모델별 TCO" 구역 헤더 안으로 이동. `ZoneHeader` 컴포넌트에 새 prop `titleExtra`를 추가해서
  (`tip` 옆, 제목 바로 뒤에 렌더) 제목 오른쪽에 "TCO 수식 확인" 버튼이 바로 붙어서 보이게 하고,
  헤더 맨 우측(`right` prop, 기존처럼 `ml-auto`)에는 "₩/USD 환율 라벨+입력창" → "원/USD 토글" →
  "엑셀 양식 붙여넣기" → "수정"(→ 수정모드 진입 시 "저장"/"취소") 순서로 한 줄에 나열되게 함.
  `ZoneHeader`는 다른 여러 구역에서도 재사용되는 공유 컴포넌트라서, 버튼 개수가 늘어난 이 구역이
  좁은 화면에서 넘치지 않도록 `.zone-head` CSS에 `flex-wrap:wrap`도 추가(다른 사용처는 원래도
  한 줄에 다 들어가므로 시각적으로 영향 없음).
- dev에 rsync 배포 완료.

### 2026-08-13 열한 번째 라운드 — "GPU 모델별 TCO"에 UI 내 직접 셀 수정 모드 신규 추가 (+ 기존 버튼 이름 정리)

- **배경**: "GPU 모델별 TCO" 구역의 기존 "수정" 버튼(`startEdit`/`editMode`)은 실제로는 표 전체를
  textarea에 TSV로 직렬화해서 엑셀에서 복사한 내용을 붙여넣는 방식이었음("반영" 버튼으로 파싱 후
  저장). 이 버튼의 이름이 "수정"이라 UI에서 직접 셀을 고치는 기능처럼 보였는데 실제로는 아니었음.
- **버튼 이름 변경**: 기존 "수정" 버튼 → **"엑셀 양식 붙여넣기"**로 이름만 변경(동작은 완전히
  동일, `startEdit`/`editMode`/`pasteDraft`/`applyEdit` 그대로).
- **신규 "수정" 모드 추가**: 새로운 state `cellEditMode`/`editDraftRows`/`cellSaveMsg`를 추가하고,
  새로운 "수정" 버튼(`startCellEdit`)을 옆에 배치. 누르면 `tcoTable.rows`를 깊은 복사해 draft로
  만들고, 상세 breakdown 표(구분/CAPEX/OPEX/TCO 등 행 × GPU 모델 열)의 값 셀이 읽기 전용 텍스트
  대신 `<input type="number">`로 바뀌어 직접 타이핑해서 고칠 수 있음. 기존 읽기전용 표와 완전히
  같은 테이블/행 렌더링 로직(행 들여쓰기, 트리 문자, CAPEX/OPEX 강조색 등)을 공유하고 값 셀만
  분기해서 코드 중복을 피함(`(cellEditMode ? editDraftRows : tcoTable.rows).map(...)`).
  라벨/구조(들여쓰기, highlight 등)는 이번엔 편집 대상 아님 — 숫자 값만 수정 가능(구조 변경은
  기존 "엑셀 양식 붙여넣기"로).
- **저장/취소**: 이 모드일 때 헤더에 "저장"(`saveCellEdits` — draft를 `tcoTable`에 반영 +
  `api.saveGpuTcoTable`로 즉시 서버 저장)과 "취소"(`cancelCellEdit` — draft 버리고 원래 표로
  복귀) 버튼이 나타남. 저장/편집 중에는 "TCO 수식 확인"/화폐단위 토글/"엑셀 양식 붙여넣기" 버튼과
  상단 요약(시간당/일당/월당/연당 TCO) 표는 숨김(파싱 모드일 때와 동일한 패턴).
- dev에 rsync 배포 완료.

### 2026-08-13 열 번째 라운드 — latest 버전 삭제 방지 + "latest로 변경(승격)" 기능 추가

- **버그**: 상단 버전 selector 옆 "이 버전 삭제" 버튼은 이미 `label !== "latest"` 조건이 있어서
  latest를 못 지웠지만, 표 하단 "저장된 버전" pill 목록(각 버전마다 `×` 버튼, index.html:8050
  부근)에는 그 조건이 전혀 없어서 거기서는 latest도 지울 수 있었음 — 지우면 activeVersion이
  존재하지 않는 versionId를 가리키게 되면서 `versions.find(...)`가 `undefined`를 반환 →
  이전 라운드에서 만든 "latest 기본 선택" 로직이 무력화되고 다시 "현재 편집 중"으로 보였던 것.
  `deleteVersion()` 함수 자체에도 `target.label === "latest"`면 즉시 return하는 가드를 추가했고
  (버튼을 어디서 실수로 호출해도 이중 방어), pill 목록의 `×` 버튼도 `{v.label !== "latest" && (...)}`
  로 감싸서 latest pill에는 애초에 삭제 버튼이 안 뜨게 함.
- **"latest로 변경" 기능 신규 추가.** 상단 selector에서 latest가 아닌 이전 버전을 선택하면(즉
  `activeVersion`이 그 버전을 가리키면) "이 버전 삭제" 버튼 왼쪽에 "latest로 변경" 버튼이 같이
  나타남(같은 조건 `activeVersion && label !== "latest"`). 클릭하면 신규 함수 `promoteToLatest
  (versionId)`가: 선택된 버전의 `label`을 `"latest"`로, 기존에 latest였던 버전의 `label`은 자기
  자신의 `versionId`(날짜 기준 문자열)로 바꿔서 — `saveVersion()`이 새로 저장할 때 이전 latest를
  날짜 라벨로 미는 것과 동일한 패턴 — 서로 자리를 바꾸고 `persistToServer`로 즉시 저장. 결과적으로
  기존 latest는 일반 버전이 되어 다시 삭제 가능해짐.
- dev에 rsync 배포 완료.

### 2026-08-13 아홉 번째 라운드 — "가속기별 성능 스펙" 버전 selector 기본값을 "현재 편집 중" → "latest"로

- **버그**: 페이지를 처음 열면(아직 아무것도 안 건드린 상태) 버전 selector가 항상 "현재 편집 중"으로
  떠 있었음. `activeVersion` state 기본값이 `null`이고, select의 `value={activeVersion || ""}`가
  빈 값이면 `<option value="">현재 편집 중</option>`이 선택되는 구조라서, 실제로는 `rows`가 마지막
  저장된 "latest" 버전 내용과 동일한데도 라벨만 "편집 중"으로 잘못 표시되고 있었음.
  (`AcceleratorPerfTab`, frontend/index.html:7298 부근)
- **수정**: (1) 초기 데이터 로드 `useEffect`에서 `versions`를 받아온 뒤 `label === "latest"`인
  버전을 찾아 `activeVersion`을 그 `versionId`로 초기화(7303번째 줄 부근 fetch effect) — 이제
  처음 열었을 때 selector가 "latest"를 정확히 선택된 상태로 보여줌. (2) "수정" 버튼 클릭 시에만
  `activeVersion`을 `null`로 바꿔서(=편집 중 상태로 진입) selector가 "현재 편집 중"으로 바뀌게 함;
  "수정 중..." 버튼을 다시 눌러 편집을 취소하면 latest 버전 id로 되돌림. (3) "저장" 버튼
  (`saveVersion()`)으로 저장 완료하면 방금 새로 생성된 버전(항상 label이 "latest")의 id를
  `activeVersion`으로 설정해서 저장 직후에도 정확히 "latest"가 선택된 상태로 표시됨. 세 지점 다
  건드려서 "편집 중" 라벨은 오직 편집 모드일 때만 보이도록 일관되게 맞춤.
- dev에 rsync 배포 완료.

### 2026-08-13 여덟 번째 라운드 — "HBM 상세 정보" 켜면 표가 더 좁아지던 버그 수정

- **"가속기별 성능 스펙" 표에서 "HBM 상세 정보" 버튼을 누르면(공정/# Die/HBM Stacks 3개 컬럼이
  추가로 나타남) 오히려 표 전체 너비가 줄어들던 버그.** 원인: `<table>` style이
  `showHbmDetail`일 때 `width:undefined, minWidth:"max-content"`로 바뀌어서, 컨테이너 100%를
  채우던 걸 그만두고 컬럼들의 `minWidth` 합만큼만 딱 맞게(content-fit) 줄어들었음 — 컬럼이
  늘었는데도 표는 오히려 좁아 보이는 역설적인 상태. `width:"100%"`로 항상 고정(showHbmDetail
  분기 제거)해서 어느 상태든 표가 항상 상위 카드 영역 전체 너비를 채우도록 수정. 각 컬럼의
  `minWidth`(`COL_DEFS[].width`)는 그대로 유지되어 최소 폭은 보장되고, 남는 폭은 브라우저의
  기본 table auto-layout이 컬럼들에 분배함 — 컬럼 수가 늘어난 만큼 각 컬럼이 상대적으로 더
  좁아지긴 하지만 표 자체가 컨테이너보다 좁아지는 일은 없음. 최소 폭 합이 컨테이너보다 넓어지는
  극단적 케이스는 기존에도 있던 `overflowX:"auto"` 래퍼가 가로 스크롤로 처리.
- dev에 rsync 배포 완료.

### 2026-08-13 여섯 번째 라운드 — 사이드바 실행상태 dot 제거 + 사이드바 접기 토글 + 성능 스펙 표 삭제버튼을 수정모드에서만 노출

- **Training/Inference 메뉴 옆 실행결과 빨간/초록 dot 완전 제거.** `Sidebar`의 `NavStatus` 컴포넌트
  (최근 run의 성공/실패/실행중 상태를 `training`/`inference` 메뉴 항목 옆에 점으로 표시하던 기능)와
  그 렌더 호출, 관련 CSS(`.nav-run-status`, `.nav-run-dot` 등), 그리고 이 기능만을 위해 존재하던
  상태/계산 체인을 전부 삭제: `App` 컴포넌트의 `dismissedRunNotices` state(+localStorage 영속화),
  `runningStatuses`/`runBelongsToTestTab`/`latestRunForSlot`/`buildTestStatus`/`testStatus`/
  `onAckTestStatus`, `Sidebar` 호출부의 `testStatus`/`onAckTestStatus` prop. `terminalStatuses`는
  `runningCount` 계산에도 쓰여서 남겨둠. grep으로 다른 소비자가 없는 것 확인 후 제거해서 죽은
  코드 없이 정리됨.
- **사이드바 접기(collapse) 토글 신규 추가 (v1, 이후 다음 라운드에서 레이아웃 수정됨).** 클릭 시
  `sidebarCollapsed` state(localStorage `platform_sidebar_collapsed_v1`에 영속화)를 토글하고,
  최상위 `.app-shell` div에 `sidebar-collapsed` 클래스를 붙여 CSS로 처리(`.app-shell.sidebar-collapsed
  { grid-template-columns: 76px 1fr; }` + 기존에 `@media (max-width:1100px)`에만 있던 라벨/서브탭/
  섹션라벨 숨김 규칙을 클래스 버전으로 복제). 기존 반응형(좁은 창에서 자동 아이콘 모드) 동작과는
  독립적으로 같이 존재함 — 서로 안 건드림. 각 `NavItem` 버튼에는 이미 `title={label}` 이 있어서
  접힌 상태에서 아이콘에 마우스 올리면 브라우저 기본 tooltip으로 라벨이 보임(추가 작업 불필요).
- **"가속기별 성능 스펙" 표의 행 삭제 버튼을 "수정" 모드에서만 보이게 변경.** 이전엔 항상 렌더링된
  `<td>`(맨 오른쪽 sticky 컬럼, `deleteRow` 버튼)를 `{editMode && (...)}`로 감쌈. 헤더 쪽의 매칭되는
  빈 `<th>`도 동일하게 `{editMode && (...)}`로 감싸서, 수정모드가 아닐 때 헤더와 바디의 컬럼 수가
  깨지지 않게 함(`editMode`는 이미 있던 "수정" 버튼이 토글하는 state, `frontend/index.html:7860`
  부근 `AcceleratorPerfTab`).
- 세 가지 모두 dev에 rsync 배포 완료.

### 2026-08-13 일곱 번째 라운드 — 사이드바 접기 버튼 위치/모양 수정 + 접었을 때 탭 본문 max-width도 비례해서 확장

- **사용자 피드백**: (1) "메뉴 접기"라는 텍스트 라벨 없이 `«`/`»` 아이콘만 있으면 됨. (2) 버튼이
  별도의 새 줄이 아니라 기존 footer의 "online · v1.2" 문구와 같은 한 줄, 그 오른쪽에 있어야 함.
  (3) 사이드바를 접으면 콘텐츠 영역이 실제로 넓어져야 함(빈 여백만 커지는 게 아니라).
- **(1)(2) 수정**: `sidebar-foot` div 구조를 `<span className="sidebar-foot-info">도트+"online · v1.2"</span>`
  + `<button className="sidebar-collapse-btn">«/»</button>` 두 children으로 재구성(`sidebar-foot`
  자체는 이미 `flex items-center`였음, 버튼에 `margin-left:auto`를 줘서 같은 줄 오른쪽 끝에 붙임).
  별도 라벨 span 제거, 버튼은 26×26px 원형 아이콘 버튼으로 축소. 접힘 시에는 `.sidebar-foot` 전체를
  숨기는 대신 `.sidebar-foot-info`(도트+텍스트)만 숨기고 버튼은 계속 보이게 해서, 접은 상태에서도
  다시 펼치는 버튼을 누를 수 있게 함(이전 버전은 `sidebar-foot`를 통째로 숨겨서 접었다가 되돌릴
  방법이 없었던 버그).
- **(3) 수정**: `.app-shell`에 CSS 변수 `--content-extra-w`를 추가(기본 `0px`,
  `.app-shell.sidebar-collapsed`와 기존 `@media (max-width:1100px)` 둘 다에서 `172px`로 설정 —
  248px(펼침 사이드바 폭) - 76px(접힌 폭) = 172px, 접었을 때 실제로 자유로워지는 폭). 탭 본문의
  최상위 `maxWidth` 컨테이너 6곳(대시보드 3개 서브탭 - 테스트결과/가속기별성능/InferenceX, 비용
  분석, Training 테스트, Inference 테스트, 각각 `frontend/index.html`의 해당 Tab 컴포넌트 `return`문
  최상위 div)을 전부 `maxWidth:"calc(1600px + var(--content-extra-w, 0px))"` (InferenceX 탭만
  1700px 기준) 형태로 변경. Training/Inference 탭 두 곳은 원래 Tailwind `max-w-[1600px]` 유틸리티
  클래스였는데, 계산식이 필요해서 인라인 `style={{maxWidth:...}}`로 전환. "테스트 클러스터 관리"
  탭이나 개별 카드/모달의 좁은 `maxWidth`(220~760px대)는 이번 대상이 아님(탭 전체 폭이 아니라
  카드 내부 요소라서 원래도 사이드바 폭과 무관).
- dev에 rsync 배포 완료.

### 2026-08-13 — Release v1.3: dev에서 검증한 이번 세션 전체 변경분을 운영(poc-platform-latest, 8100)에 배포

이번 세션(2026-08-13, 두 번째~열네 번째 라운드)에서 dev(8101)에 올려 사용자가 직접 확인한
변경분을 모두 운영으로 승격. 버전 문자열을 v1.3으로 갱신(사이드바 하단 "online · v1.3", 콘솔
푸터). 주요 내용 요약(자세한 내용은 위 각 라운드 참고):

- 대시보드 · 가속기별 성능: CAGR 추세선이 from GPU 연도부터 그려지도록 수정, 성능 스펙 표 삭제
  버튼을 수정 모드에서만 노출, 버전 selector 기본값을 "latest"로(편집 중은 수정 버튼 누를 때만),
  latest 버전 삭제 방지 + "latest로 변경(승격)" 기능, "HBM 상세 정보" 켜면 표가 좁아지던 버그 수정.
- 대시보드 · 비용 분석: GPU 모델별 TCO 표에 UI 내 직접 셀 수정 모드 신규 추가(기존 "수정" 버튼은
  "엑셀 양식 붙여넣기"로 이름 변경), 헤더 레이아웃 재배치(₩/USD 환율 입력을 GPU 모델별 TCO 헤더로
  이동, TCO 수식 확인 버튼을 제목 옆으로).
- 테스트 탭(Training/Inference 공통, NodeAdder): hostname 라벨을 "IP/hostname"으로, placeholder에
  IP 예시 추가, 입력창들을 더 넓고 눈에 띄게(보라색 테두리+글로우), PD 2단 레이아웃에서 오버플로로
  깨지던 정렬 수정.
- 사이드바: Training/Inference 메뉴의 실행상태 dot 완전 제거, 사이드바 접기(collapse) 토글
  신규 추가(접으면 탭 본문 max-width도 비례 확장).
- 전역: 숫자 입력의 브라우저 기본 스피너를 전역 CSS 규칙으로 제거(앞으로 필드별로 다시 스코프
  하지 않기로 함).
- 배포/운영: `start_platform.sh`에 venv 깨짐 자동 복구 로직 + `module load python-3.13.0` 자동
  로드 단계 추가(이 스크립트는 latest/dev 공용이라 이번에 같이 반영됨), dev 배포 폴더명을
  `poc-platform-dev`로 고정, dev 전용 state 디렉토리(`.poc_platform_dev_state`)로 latest와 분리.

git 태그 `v1.3`으로 릴리즈, GitHub push.
