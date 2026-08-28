# HISTORY

이 파일은 다른 Claude 세션이 이 저장소에서 작업을 이어갈 때 알아야 할 배경 지식과
작업 히스토리를 정리한 문서입니다. 새로운 세션은 작업 시작 전에 이 파일을 먼저 읽으세요.

**사용자 요청(2026-08-12): 이 파일은 사용자가 별도로 요청하지 않아도, 의미 있는 수정/버그
수정/기능 추가를 할 때마다 매번 자동으로 갱신할 것.** git commit 여부와 무관하게(아직 테스트
중이라 커밋 전이어도) 작업 단위가 끝나면 그때그때 반영한다.

## 배포 토폴로지

```
GitHub
   ↕ 로컬 PC에서 git pull/push
로컬 ~/poc-platform  (개발 편집 위치, 이 세션이 도는 머신)
   ↕ rsync (mount-aii, /mnt/share/... 로 마운트됨)
폐쇄망 서버 /opt/poc-platform/
   ├── poc-platform-latest/       ← 8100, systemd 서비스 `poc-platform.service`로 상시 구동
   ├── poc-platform-dev/          ← dev/디버깅용 배포 폴더(고정 폴더명). 보통 8101 등 다른 포트로 기동
   │                                 (2026-08-13 이전에는 `poc-platform-vX.Y.Z` 버전 스냅샷 폴더명을
   │                                 그대로 썼으나, 폐쇄망 서버에서 `poc-platform-dev`로 고정함)
   ├── files/                     ← air-gapped pip wheelhouse
   ├── data/                      ← 벤치마크 데이터/모델/이미지
   ├── .poc_platform_state/       ← latest(8100)가 쓰는 JSON 상태 저장소 (아래 참고)
   └── .poc_platform_dev_state/   ← dev(8101)가 쓰는 JSON 상태 저장소 (2026-08-13부터 latest와 분리)
```

- 로컬에서 폐쇄망으로 파일을 올릴 때는 `rsync`를 직접 사용합니다(현재 이 세션은 SSH가 아니라
  `/mnt/share/...` 마운트를 통해 파일시스템으로 접근). `sync.sh <version>`은 로컬 저장소를
  `poc-platform-<version>/`으로 올리는 스크립트지만, 이 세션에서는 대부분 직접 rsync 커맨드를
  써왔습니다(`--exclude .git .claude .venv __pycache__ *.pyc .poc_platform.log .poc_platform_state`,
  대상 폴더의 `start_platform.sh`가 로컬과 다르면(서버에서 직접 고친 PORT 기본값 등)
  `--exclude start_platform.sh`도 추가해서 덮어쓰지 않기).
- 로컬 PC에서 git pull/push, rsync 하는 방법
  git -C ~/other-project fetch origin main && git -C ~/other-project reset --hard origin/main
  rsync -avz --delete --progress ~/other-project/ pocuser@{서버ip}:/opt/other-project/ 2>&1
- **8100(`poc-platform.service`)**: `/etc/systemd/system/poc-platform.service`가 이미 존재.
  코드 갱신 후에는 `systemctl restart poc-platform.service`로 재기동(코드만 바뀐 게 아니라
  `backend/app.py`/`state.py`처럼 백엔드가 바뀐 경우 반드시 재시작 필요, `frontend|backend/index.html`만
  바뀐 경우는 새로고침만 하면 됨 — `/` 라우트가 `FileResponse`로 매 요청마다 디스크에서 새로 읽음).
  유닛 파일 원본은 README.md의 "운영 배포 (systemd)" 섹션에 있음.
- **디버그 버전(`poc-platform-dev/`, 예: 8101)**: systemd 없이 `PORT=8101 ./start_platform.sh`로
  수동 기동(또는 README의 `poc-platform-dev.service`로 상시 구동). 서버 쪽 `start_platform.sh`가
  로컬과 다를 수 있음(예: `PORT` 기본값이 8101로 직접 수정돼 있는 경우) — rsync 전에 diff로 확인.

## 파일 구조 관련 중요 함정

- **`frontend/app.jsx`는 신뢰하지 말 것.** `frontend/index.html`의 `<script type="text/babel">`
  인라인 블록이 실제로 브라우저에 서빙되는 코드의 원본입니다. `app.jsx`는 예전 스냅샷이고 지금은
  index.html보다 몇 천 줄 적은 구식 파일입니다(예: "가속기별 성능", "비용 분석" 탭 자체가 app.jsx에는
  없음). 편집 대상이 아님.
- **`backend/index.html`은 실제로 어디서도 서빙되지 않는 미사용 파일입니다.** `backend/app.py`의
  `/` 라우트는 `FRONTEND_DIR/index.html`(=`frontend/index.html`)만 읽고, `backend/index.html`을
  참조하는 코드는 저장소 전체에 없음(2026-08-11 확인). 이 세션은 2026-08-11 작업 내내
  `backend/index.html`도 `frontend/index.html`과 동일하게 고쳐왔는데(원래는 "두 파일을 항상 동일하게
  유지"가 원칙인 줄 알았음), 나중에 보니 `DashboardTab`의 `testKind` 초기값이나 드래그앤드롭 행
  재정렬 기능처럼 **이미 예전부터 두 파일이 서로 다른 부분들이 있었음** — 즉 누군가(또는 예전 세션)가
  `backend/index.html`을 빠뜨리고 `frontend/index.html`만 고친 적이 이미 여러 번 있었다는 뜻.
  **결론: `backend/index.html`은 죽은 파일이니 굳이 같이 고칠 필요 없음.** 다만 삭제할지는 사용자
  확인 후 결정(2026-08-11 세션에서는 삭제하지 않고 존재만 알려둔 상태). 이후 세션은 편집을
  `frontend/index.html`에만 하면 됨 — `backend/index.html`을 계속 미러링하느라 시간 쓰지 말 것
  (사용자가 삭제하지 않는 한, 이미 드리프트된 상태로 방치되어 있다는 점만 유의).
- 이 파일들은 4000~14000줄대의 초대형 단일 파일이라 Edit 툴의 정확한 old_string 매칭이 위험할 때는
  Python으로 라인 범위를 잘라서 교체(splice)하는 방식을 씀. 편집 후에는 항상:
  ```bash
  python3 -c "s=open(path,encoding='utf-8').read(); print(s.count('{')-s.count('}'), s.count('(')-s.count(')'))"
  ```
  로 중괄호/괄호 균형을 확인(단, 소괄호는 원래도 -4로 안 맞는 상태가 기본값이라 이상 아님 — git HEAD
  버전에서도 동일하게 -4였음, 이모지/텍스트 안의 괄호 때문으로 추정).
- `frontend/index.html` ↔ `backend/index.html`의 `CostAnalysisTab`/`AcceleratorPerfTab` 등 특정 함수
  블록이 서로 완전히 동일한지 diff로 항상 재확인:
  `diff <(sed -n '/function XxxTab/,/^ function YyyTab/p' frontend/index.html) <(같은 걸 backend에)`

## `.poc_platform_state/` (구 공유) JSON들

`backend/state.py`의 `STATE_DIR` 환경변수는 `POC_PLATFORM_STATE_DIR`이며, 지정하지 않으면
기본값은 배포 폴더의 부모 폴더 + `.poc_platform_state/`. **2026-08-13 이전**에는 latest(8100)와
dev(8101) 둘 다 이 기본값을 그대로 써서 상태(가속기별 성능·비용 분석 표 등)를 공유했음 — dev에서
편집하면 latest에도 바로 반영되는 문제가 있었음.

**2026-08-13부터**: `poc-platform-dev.service`에 `Environment="POC_PLATFORM_STATE_DIR=.../.poc_platform_dev_state"`를
추가해 dev를 완전히 분리함(README.md "DEV/디버그 배포" 섹션 참고). 분리 당시 기존 `.poc_platform_state/`를
`rsync -a`로 `.poc_platform_dev_state/`에 그대로 복사해 시드 데이터로 씀 — 그 시점 이후로는 두
디렉토리가 서로 독립적으로 갈라짐(dev에서 테스트하다 잘못 편집해도 latest/운영 데이터에 영향 없음).

- `accelerator_perf.json` — "가속기별 성능" 탭. `{rows, history, versions, row_order}`.
  `versions` 배열로 버전 관리(저장 시점 스냅샷) 기능이 이미 있음.
- `gpu_tco_table.json` — "비용 분석" 탭의 GPU 모델별 TCO 표(오늘 신규 추가).
  `{columns: [GPU 모델명...], rows: [{label, indent, values:{모델명:숫자}, highlight}], tps_assignments: {모델명:{value,source,label}}}`.
  **아직 버전 관리 기능 없음** — accelerator_perf.json처럼 versions 배열을 추가할지 검토 중
  (2026-08-11 세션에서 논의, 미구현).
- `tco_profiles.json` — 예전 비용분석 UI(GPU 1종 선택 + CapEx/OpEx 입력)가 쓰던 저장소.
  지금 CostAnalysisTab은 더 이상 참조하지 않지만 엔드포인트/데이터는 남아있음(죽은 코드는 아니고
  백엔드 엔드포인트 자체는 유지 중, 프론트에서만 안 씀).
- `dashboard.json`, `runs.json`, `official_records.json` — 기존 실행 결과/대시보드 pin 저장소.

## 이 마운트(`/mnt/share/...`)에서 파일 쓸 때 주의

- **새 파일 생성/`rsync`로 기존 파일 덮어쓰기는 잘 됨.** 하지만 Python `open(path,'w')` 직접 쓰기나
  `os.replace(tmp, path)`(atomic rename)로 **이미 존재하는 파일을 교체하는 것은 `PermissionError:
  [Errno 1] Operation not permitted`로 실패**함(SFTP rename-over-existing 제약으로 추정). 해결:
  로컬 임시 파일에 쓰고 `rsync -av 로컬임시파일 마운트경로`로 복사(성공 확인됨). 실패한 시도가
  `*.tmp` 파일을 남길 수 있으니 정리할 것.
- rsync/쓰기 직후 바로 `diff`를 뜨면 아주 가끔 파일이 텅 빈 것처럼 보이는 **일시적인 FUSE 캐시
  글리치**가 있었음(1~2초 후 재확인하면 정상). 크기/줄수가 로컬과 같은데 diff가 이상하면 재시도.
- `.poc_platform_state/` 안의 JSON을 직접 patch할 일이 생기면(코드 버그로 잘못 저장된 필드를
  수동 교정하는 등) 위 rsync 우회법을 쓸 것.

## 알아두면 좋은 데이터/파싱 관련 함정

- **엑셀의 "들여쓰기"는 셀 서식(비주얼) 속성**이라 일반 텍스트로 복사하면 앞쪽 공백이 전혀
  남지 않습니다. "줄 앞 공백 수로 들여쓰기 추정" 방식은 실제 엑셀 붙여넣기에서는 항상 0이
  나와서 실패함 — CostAnalysisTab의 `KNOWN_ROW_INDENT` 라벨→들여쓰기 매핑 테이블을 쓰는 이유.
  새 항목명을 추가할 땐 이 맵도 같이 갱신해야 트리 표시(├/└)가 제대로 나옴.
- **엑셀 셀 병합**도 흔한 함정: 라벨 칸이 여러 칸 병합돼 있으면 그 폭만큼 빈 탭 셀이 따라옴(병합
  폭은 행마다 다름). `parseTsv`는 "헤더/각 행 모두 뒤에서부터 GPU 모델 개수(N)만큼을 값으로,
  그 앞의 비어있지 않은 셀 전부를 라벨로" 잡는 방식으로 안전하게 처리함 — 고정 오프셋으로
  자르면 반드시 깨짐.
- 붙여넣기는 탭(TSV) 또는 공백 2개 이상 어느 쪽이든 자동 인식(`splitPastedCells`). textarea는
  "수정" 진입 시 자동으로 전체 선택되어(useEffect + ref.select()) 바로 Ctrl+V만 해도 전체 교체됨.
- `serializeTsv`가 다시 textarea에 채워줄 때 **헤더 첫 칸에 항상 비어있지 않은 라벨 텍스트를
  넣어야** 함(`parseTsv`가 헤더의 첫 non-empty 셀을 라벨로 간주하고 버리기 때문 — 비워두면
  실제 컬럼명 하나가 라벨로 오인되어 밀림). 2026-08-11에 이 버그를 발견/수정함(자세한 내용은
  git log의 관련 커밋 참고).

## 2026-08-11 세션 작업 요약 (v1.0 → v1.1)

- **가속기별 성능 탭**: Rubin/Rubin Ultra 행 추가 및 데이터시트 링크(Vera Rubin, Hopper) 갱신,
  FP4 Sparse 컬럼 제거(Dense만 "FP4"로 표시), NVL72(kW) 컬럼 제거, FP64/32/16/8 라벨의 "(TF)"
  단위 표기 제거.
- **비용 분석 탭 전면 재작성**: 기존 "GPU 1종 선택 + CapEx/OpEx 직접입력 + 신규가속기분석" 구조를
  걷어내고, 사내 원가시트 그대로의 "GPU 모델별 TCO" 표(CAPEX=서버+네트워크+운영서버+스토리지,
  OPEX=유지보수+전기료+상면비, 트리 시각화) + "토큰 단가 비교" + "실험 결과 반영"(공식/테스트
  결과 대시보드에서 TPS 가져오기) 3개 구역으로 교체. 신규 백엔드: `GET/PUT /api/gpu-tco-table`
  (`backend/app.py`, `backend/state.py`).
- 버전 문자열을 v1.1로 갱신(사이드바 하단 "online · v{ver}", 콘솔 푸터).
- git 태그: 기존 `v6.64` → `v1.0`으로 rename(로컬+리모트), 오늘 작업을 커밋해 `v1.1`로 릴리즈.
  이후 버저닝은 `v6.x` semver 스타일이 아니라 `v1.x`로 새로 시작.
- 이 커밋들을 로컬 저장소, 폐쇄망 `poc-platform-v6.64`(8101 디버그), `poc-platform-latest`(8100,
  `systemctl restart poc-platform.service` 필요) 모두에 반영함.

### 2026-08-11 두 번째 라운드 — 버그 3건 수정 + CAGR UI + 비용분석 재구성 1차 (commit b380502, merge cbdca32, GitHub 반영됨)

- **테스트 결과 대시보드 첫 진입 시 차트 미표시 — 수정.** 원인: `DashboardTab`의
  `category` 기본값은 `"training"`인데 `testKind` 기본값이 `"vllm"`으로 서로 안 맞는 조합이었음
  (training의 유효 testKind는 `"mlperf"`뿐). 첫 렌더에서 `projected`(핀 목록)가 빈 배열로
  확정되어 차트 `<ResponsiveContainer>`가 DOM에 아예 없다가, `useEffect`가 나중에 `testKind`를
  고치면서 뒤늦게 재마운트되어 크기 측정이 깨짐. 고침: `testKind` 초기값을 `"mlperf"`로 통일.
  *`backend/index.html`은 이미 `"mlperf"`였음 — 이게 바로 위 "backend/index.html은 죽은 파일"
  발견의 계기.*
- **비용 분석 탭 재편집시 헤더 소실 — 수정.** `serializeTsv`가 헤더 첫 칸을 빈 문자열로 써서,
  재파싱 시 실제 컬럼명(V100 등) 하나가 라벨로 오인되어 전부 밀리는 버그. 첫 칸에 `"GPU 모델"`
  고정 라벨을 쓰도록 수정.
- **가속기별 성능 탭 CAGR 기준 GPU UI 선택 — 신규 구현.** 기존엔 CAGR 계산 기준(첫/마지막 GPU)이
  "2022년 이후 첫 포인트 ~ 올해 이하 마지막 포인트"로 코드에 고정. 이제 벤더별로 "CAGR 기준"
  select 2개(From GPU/To GPU)를 UI로 직접 고를 수 있게 함(`cagrRangeOverride` state,
  `vendorCagrOptions`/`cagrRangeFor`/`setCagrEndpoint` 헬퍼, `AcceleratorPerfTab` 내부).
  NVIDIA 기본값은 `CAGR_DEFAULT_ID`로 H100→B300 하드코딩, 없으면 자동 로직 폴백.
- **비용 분석 탭 구조 변경**: "실험 결과 반영" 구역을 없애고 "토큰 단가 비교" 구역 맨 위로 통합.
  점선(CAGR 예측선)은 실제 데이터 구간(from~to)에는 안 그리고 to 연도부터(포함) 미래로만.

### 2026-08-12 세 번째 라운드 — CAGR 데이터 편향 버그 + 비용분석 UI 개선 (아직 미커밋)

- **CAGR 기본 구간이 FP4처럼 특정 연도(2025)에 데이터가 몰린 지표에서 점선이 전혀 안 나오던
  버그 — 수정.** 원인: `cagrRangeFor`의 "to" 기본값이 `release_year <= CURRENT_YEAR(2026)`만
  보는데, 유일하게 더 늦은 연도(Rubin 2027)를 제외하고 나면 from/to 후보가 전부 2025년으로만
  남아서 `n = to.year - from.year = 0`이 되어 CAGR을 계산 못 함(`if (n===0) return null`).
  고침: "from과 연도가 다른" 포인트 중 이미 출시된 마지막 것을 우선, 없으면 연도만 다르면 되는
  전체 마지막 포인트로 폴백하도록 `cagrRangeFor` 로직 변경. **비슷한 지표에서 CAGR 점선이 다시
  안 보이면 이 로직부터 의심할 것.**
- **비용 분석 탭 계속 진행 중인 재구성**:
  * "토큰 단가 비교" GPU별 카드: 최저가뿐 아니라 최고가도 배지로 표시(`priciestCostKrw`,
    1개뿐이면 표시 안 함). "공식 결과"/"테스트 결과" → "공식 결과 대시보드"/"테스트 결과
    대시보드"로 라벨 명시화. 배정 시(`applyAssignment`) 구조화된 `detail` 객체(모델/Hardware/
    Framework/TP/Concurrency/Throughput 또는 GPU타입/Run ID/Input·Output tok/s)를
    `tpsAssignments[col].detail`에 같이 저장하고, 카드에 마우스오버(`hoveredGpuCard` state)시
    커스텀 팝오버로 상세 표시(브라우저 기본 `title` 툴팁 대신).
  * "신규 가속기 도입 TCO 분석" 구역 레이아웃을 세로 스택(표 위, 비교표 아래)에서 좌우
    2단(`grid-template-columns`, 왼쪽=CAPEX/OPEX 세부 비교표(`tableLayout:fixed`로 컬럼폭 고정),
    오른쪽=신규/비교 GPU 카드 2개(시간당·일당·월당 TCO, TPS, 1M당단가))으로 변경.
    ZoneHeader 설명문을 "서버 가격에서 기존 비율 적용하여 기존 가속기와 CAPEX/OPEX, TCO
    비교 분석"으로 변경.

### 2026-08-12 네 번째 라운드 — 신규 가속기 도입 TCO 분석 세부화 + 레이아웃 개선 (아직 미커밋)

- **트리 렌더링 헬퍼 리팩터링**: `computeGroupColors`/`computeNetworkGuide`/`computeTreeChars`를
  `tcoTable.rows`에 종속된 인라인 계산에서 `rows` 배열을 받는 순수 함수로 뽑아냄. label/indent만
  보고 동작하므로 메인 TCO 표(구역 A)와 "신규 가속기 도입 TCO 분석"(구역 C)의 breakdown 표
  양쪽에서 그대로 재사용 — 트리 시각화(├/└, CAPEX/OPEX 좌측 보더, 네트워크 서브가이드)가
  두 표에서 동일하게 보임.
- **"신규 가속기 도입 TCO 분석" 리프 레벨까지 확장**: 기존엔 네트워크/운영비를 통짜로 하나의
  값으로만 비율 추정해서 보여줬는데, 이제 Infiniband/Ethernet/케이블 포설(네트워크의 자식),
  유지보수/전기료/상면비(운영비의 자식)까지 각각 개별적으로 서버가격 비율 추정 + 클릭 오버라이드
  가능. 네트워크/운영비 자체는 그 자식들의 합으로만 계산되는 집계행이 되어 더 이상 직접
  수정하지 않음(메인 TCO 표와 동일한 구조 — 이중 소스오브트루스 방지).
- **비율 안내 문구**: "{ref} 대비 서버 가격 비율 {x}× 적용" → "{ref} 대비 항목별 서버 가격
  비율({x}×) 적용"으로 변경(네트워크/운영서버/스토리지/운영비뿐 아니라 그 하위 리프 항목까지
  전부 같은 비율이 적용된다는 걸 명확히).
- **레이아웃**: 왼쪽 breakdown 표(CSS grid stretch로 오른쪽과 세로 길이 맞춤, `tableLayout:fixed`
  제거하고 `whiteSpace:nowrap`으로 자연스러운 컬럼폭), 오른쪽은 신규/비교 GPU 카드를 세로 스택이
  아니라 가로로 나란히 배치 + 그 아래 "비교 분석" 박스 추가(TCO·1M당단가를 `analysisDelta`로
  %변화 계산, 신규가 더 나쁘면(비쌈) 빨간색 "최고가"와 동일한 `#CF6679`, 더 좋으면(저렴)
  `#03DAC6` 청록으로 표시).

### 2026-08-12 다섯 번째 라운드 — "신규 가속기 도입 TCO 분석" 레이아웃 재조정 + 토큰단가 비교 팝오버 개선 (아직 미커밋)

- **트리 헬퍼 재사용 가능하게 리팩터**: `computeGroupColors`/`computeNetworkGuide`/`computeTreeChars`를
  `tcoTable.rows`에 종속된 인라인 계산에서 `rows` 배열을 받는 순수 함수로 뽑음(label/indent만 보고
  동작) — 메인 TCO 표(구역 A)와 "신규 가속기 도입 TCO 분석"(구역 C) breakdown 표 양쪽에서 동일한
  트리 시각화(├/└, CAPEX/OPEX 좌측 보더, 네트워크 서브가이드) 재사용.
- **breakdown 표**: 컬럼 순서를 [구분, 신규, 비교] → **[구분, 비교, 신규]**로 변경, `<colgroup>`으로
  두 값 컬럼 너비를 동일하게(86px) 고정해 "간격이 일정하지 않다"는 문제 해결, 좌측 그리드 비율을
  `1.3fr → 0.85fr`로 줄여 표 자체를 더 좁게.
  안내 문구를 "{ref} 대비 항목별 서버 가격 비율({x}×) 적용 — ... 클릭하면 수정..." 같은 긴 설명에서
  **"{ref} 대비 항목별 서버 가격 비율 적용(신규 가속기 값 클릭 후 수정 가능)"**로 단순화.
- **오른쪽 카드**: 별도 "비교 분석" 박스를 없애고, 카드 순서를 [신규, 비교] → **[비교, 신규]**로 변경.
  카드를 더 크게(패딩 20-22px, `metricBlock` 헬퍼로 시간당 TCO/일당·월당 TCO/TPS/1M당단가를 각각
  분리된 블록으로 명시적으로 표시). **신규 가속기 카드에서만** 각 지표 옆에 `analysisDelta`로 계산한
  "(00.0% 증가/감소)"를 인라인 표시 — TCO/단가는 낮을수록 좋음(초록 `#03DAC6`)/높으면 나쁨
  (빨강 `#CF6679`, "최고가"와 동일 색), TPS는 높을수록 좋음으로 반대 방향 적용.
- **토큰 단가 비교 카드**: `sourceLabel`을 "공식 결과 대시보드"/"테스트 결과 대시보드" → 다시
  짧은 "공식 결과"/"테스트 결과"로 되돌림(한 라운드 전에 길게 늘렸던 걸 되돌린 것 — 라벨 길이는
  사용자 취향에 따라 왔다갔다 할 수 있으니 향후에도 유연하게 대응). 상세 정보 팝오버를 카드
  아래 고정 위치(`position:absolute`)에서 **마우스 커서를 동적으로 따라다니는 방식**
  (`position:fixed` + `onMouseMove`로 `hoveredGpuPos` 갱신, 화면 경계에서 넘치지 않게 clamp)으로 변경.

### 2026-08-12 여섯 번째 라운드 — 팝오버 미표시 버그 수정 + 표/입력 UI 정리 + 카드 3구역화 (아직 미커밋)

- **커서 따라다니는 팝오버가 전혀 안 보이던 버그 — 수정.** 원인: 팝오버 렌더 조건이
  `if (!hovered?.detail) return null`인데, `.poc_platform_state/gpu_tco_table.json`에 이미
  저장돼 있던 `tps_assignments`는 전부 `detail` 필드가 추가되기 *이전*에 배정된 것들이라
  `{value, source, label}`만 있고 `detail`이 없음 — 그래서 항상 null 반환되어 아무것도
  안 보였음. 고침: `detail`이 없으면 기존 `label`(sourceDetail) 문자열을 `[["정보", label]]`
  한 줄로 폴백해서 항상 뭔가는 보이게 함. **앞으로 새로 스키마 필드를 추가할 때는 기존
  `.poc_platform_state/*.json`에 그 필드가 없는 레코드가 있을 수 있다는 걸 항상 감안할 것
  (마이그레이션 없이 점진적으로 스키마가 늘어나는 구조이기 때문).**
- **"신규 가속기 도입 TCO 분석" 표 폭 문제 — 수정.** `width:"100%"` + 라벨 컬럼만 `<col>`에
  width 미지정이라 `table-layout:auto`에서 라벨 컬럼이 남는 공간을 전부 흡수해 과도하게
  넓어짐. `tableLayout:"fixed"`로 되돌리고 라벨 컬럼도 `<col style={{width:"148px"}}>`로
  명시(값 컬럼은 84px×2 유지) — 이제 표가 grid 셀 너비에 상관없이 항상 148+84+84px로 고정.
- **입력 라벨/폭 정리**: "서버(자가소비 포함) 가격 (원/시간/GPU)" 한 줄 라벨 → "서버 가격"
  (큰 글씨) + "(자가소비 포함, 원/시간/GPU)"(작은 회색 글씨, 줄바꿔서) 2줄로. "비율 적용 기준
  GPU" → "TCO 비율 기준 GPU", "TPS (tok/s)" → "TPS (TOK/s)"로 라벨 텍스트 변경. 각 입력/셀렉트
  폭을 라벨 텍스트 길이에 맞춰 재조정(서버가격 210px, TCO 비율 기준 GPU 170px, TPS 140px,
  비교 GPU 150px).
- **오른쪽 비교/신규 카드를 TCO·TPS·1M당단가 3개 구역으로 명확히 분리**: 각 구역에 소제목
  ("TCO 비교"/"TPS 비교"/"1M 토큰당 단가 비교") + 구분선 추가. `metricBlock`의 `big` 플래그를
  `tier:"primary"|"secondary"`로 바꿔서, **시간당 TCO만 27px(가장 큼)**, 나머지(일당·월당
  TCO/TPS/1M당단가)는 전부 동일한 19px로 통일(전에는 1M당단가만 유독 컸음). 신규 카드의
  각 지표 옆 델타(%)는 그 지표가 속한 구역 안에서만 표시.

### 2026-08-12 일곱 번째 라운드 — 팝오버 위치 버그 근본 수정 + 전체 상세 데이터 + 정렬/레이아웃 마무리 (아직 미커밋)

- **커서 따라다니는 팝오버가 커서에서 한참 떨어져 뜨던 버그 — 근본 원인 수정.** 이전 수정(clamp)은
  증상 완화였을 뿐, 진짜 원인은 팝오버가 `CostAnalysisTab`의 `.fade-up`(마운트 애니메이션,
  `transform` 사용) 등 조상 요소 내부에 그려지면서 `position:fixed`의 기준점이 뷰포트가 아니라
  그 조상 요소로 잡혔던 것. **`ModalPortal`(이미 다른 모달에서 쓰던 `ReactDOM.createPortal` 래퍼)로
  `document.body`에 직접 그리도록 변경**해서 완전히 해결. `zIndex`도 9999로 올림. **앞으로 화면
  전역에 떠야 하는 툴팁/팝오버/드롭다운을 만들 때는 처음부터 `ModalPortal`을 쓸 것 — 조상에
  transform/animation/filter가 있으면 `position:fixed`만으로는 커서 근처에 못 뜬다.**
- **공식 결과 상세 팝오버에 전체 필드 표시**: 기존엔 모델/Hardware/Framework/TP/Concurrency/
  Throughput/Interactivity 6~7개만 골라서 보여줬는데, 이제 `cand.row`의 모든 필드(빈 값만 제외,
  숫자는 소수 2자리로 정리)를 그대로 보여줌 — Precision/EP/DP Attention/ISL/OSL/Mean TTFT/TPOT/
  E2E Latency(Mean/Median/P99)/Disaggregated/Is Multinode/Date 등 전부 포함.
- **입력 필드 4개(서버가격/TCO 비율 기준 GPU/TPS/비교 GPU) 라벨·입력창 수평 정렬**: 라벨을
  `height:"30px"` 고정 + 컨테이너를 `alignItems:"flex-start"`로 바꿔서, "서버 가격" 라벨이
  2줄이어도 모든 라벨이 같은 줄에서 시작하고 그 아래 입력/셀렉트도 같은 줄에서 시작하게 함.
- **왼쪽 breakdown 표를 다시 전체 폭 사용 + 정확히 1/3씩 균등 분할**로 변경(구분/비교/신규
  각 33.3%, `width:"100%"` 복원) — 전 라운드에 너무 좁게 고정했던 걸 되돌리고 "구분 칸이 넓다"는
  피드백과 "표가 카드 구역과 멀리 떨어져 있다"는 피드백을 동시에 만족.
- **오른쪽 카드 정리**: 신규 가속기 카드의 일당/월당 TCO에서 중복 표시되던 델타(%)를 제거하고
  시간당 TCO 옆에만 남김(세 값 다 같은 비율이라 하나만 있으면 됨). TPS/1M 토큰당 단가 구역은
  `metricBlock`에 `hideLabel:true`를 넘겨서 자체 라벨을 숨기고 섹션 제목만 남김. 섹션 제목
  ("TCO 비교"/"TPS 비교"/"1M 토큰당 단가 비교")을 11px 무채색 → 13px `#c9c5d6` 굵게로 키워서
  더 잘 보이게 함.

### 2026-08-12 여덟 번째 라운드 — "신규 가속기 도입 TCO 분석" 기본값 채워서 바로 보이게 (아직 미커밋)

- `newGpuServerPrice`/`newGpuRefModel`/`newGpuTps`/`newGpuCompareModel`의 초기값을 빈 문자열에서
  `"4000"`/`"B300"`/`"10000"`/`"B300"`으로 변경 — 탭 진입 즉시 breakdown 표와 비교 카드가 모두
  채워진 상태로 보임(예전엔 사용자가 4개 다 입력해야 아무것도 안 보였음).

### 2026-08-12 아홉 번째 라운드 — "GPU 모델별 TCO" 구역 폰트/문구 정리 (아직 미커밋)

- 시간당/일당/월당/연당 TCO 미니 표 위의 캡션("GPU별 TCO — 시간당 · 일당 · 월당 · 연당") 삭제 —
  표가 바로 보이게.
- 그 미니 표 안에서 "시간당 TCO" 행만 크게(15px, 굵게 유지), 나머지(일당/월당/연당) 행은
  글자 크기는 그대로(13px)지만 **bold 제거**(fontWeight 600/700 → 400)해서 시간당이 확실히
  눈에 띄게.
- 아래 CAPEX/OPEX 상세 breakdown 표 전체 폰트 확대: 기본 13px→15px, TCO 강조행 14px→17px,
  트리 커넥터/캡션 문구도 비율 맞춰 소폭 확대. "잘 안 보인다"는 피드백 반영.

### 2026-08-12 열 번째 라운드 — 상세 breakdown 표 폰트 되돌림 + 수식 캡션 한 줄로 (아직 미커밋)

- 방금 15px/17px로 키운 게 너무 컸다는 피드백 — 기본 13px로 되돌리고, **강조행(TCO)만 15px**로.
- "TCO" 아래 줄바꿔서 뜨던 "= CAPEX + OPEX" 같은 캡션을, 라벨과 같은 한 줄(`display:flex`
  가로 배치)에 나오도록 변경 — `rowCaption()`은 그대로 재사용, 렌더 위치만 별도 `<div>`(줄바꿈)
  에서 라벨과 같은 flex row 안 `<span>`으로 이동.

### 2026-08-12 열한 번째 라운드 — 상세 breakdown 표 CAPEX/OPEX 강조행화 + 구분 열 너비 고정 (아직 미커밋)

- **CAPEX("감가비(직투)")/OPEX("운영비") 행도 TCO처럼 강조행으로 취급.** 기존엔 `r.highlight`
  (TCO 행)만 15px/배경색 강조를 받고 CAPEX/OPEX는 `labelColor`가 있어 굵게(bold)만 됐었음.
  `isMajor = r.highlight || !!labelColor`로 통합해 CAPEX/OPEX도 폰트 15px(다른 행은 13px 유지)로
  커지도록 변경. `<tr>` 배경도 TCO의 `#BB86FC22`처럼, CAPEX/OPEX는 각자의 `labelColor`(주황/시안)
  + 투명도 `18`을 섞은 은은한 배경 틴트를 추가(`rowBg = r.highlight ? "#BB86FC22" : (labelColor ? `${labelColor}18` : undefined)`).
- **"구분" 열 너비가 너무 넓다는 피드백 — 고정.** 표에 `tableLayout:"fixed"` + `<colgroup>`
  추가: 구분 열은 `200px` 고정(길어도 `overflow:hidden; textOverflow:"ellipsis"`로 잘림 처리),
  나머지 GPU 값 열들은 `calc((100% - 200px) / N)`으로 N개 GPU가 항상 균등한 폭을 갖도록 함
  (N = `tcoTable.columns.length`, 이 표는 "구분/비교/신규" 미니 표(구역 A 위쪽, line ~8590)와는
  별개 — 그건 그대로 둠, 헷갈리지 말 것).
- 대상: 구역 A "GPU 모델별 TCO"의 메인 상세 CAPEX/OPEX/TCO breakdown 표 (구역 C "신규 가속기
  도입 TCO 분석"의 breakdown 표는 이미 별도로 `tableLayout:fixed` + 고정 px 컬럼을 쓰고 있어서
  이번 변경 대상 아님).

### 2026-08-12 열두 번째 라운드 — 세부 수식 캡션 제거 + "TCO 수식 확인" 모달 신규 추가 (아직 미커밋)

- **"= 서버 + 네트워크 + ..." 같은 세부 캡션이 열 너비 200px 고정 이후 줄바꿈 없이 잘려 보이던
  문제 — 해결.** `rowCaption(label)`이 TCO/감가비(직투)/운영비/네트워크 4개 라벨 모두에 캡션을
  달아주고 있었는데, 구분 열이 고정폭(200px)이 되면서 "TCO" 캡션("= CAPEX + OPEX")보다 긴
  "= 서버 + 네트워크 + 운영서버 + 스토리지" 등이 잘림. 사용자 요청대로 **TCO 행의
  "= CAPEX + OPEX"만 남기고 나머지 3개(감가비(직투)/운영비/네트워크) 캡션은 전부 제거**.
- **"GPU 모델별 TCO" 구역 제목 옆에 "TCO 수식 확인" 버튼 신규 추가.** 클릭 시 `TcoFormulaModal`
  (신규 컴포넌트, `ModalPortal`로 `document.body`에 직접 렌더 — 기존 `RunDeleteConfirmDialog`와
  동일한 중앙 배치 모달 패턴 재사용)이 열리며, 사용자가 제공한 GPU_TCO_per_hour 산출 공식을
  4개 항(CAPEX / OPEX·유지보수 / OPEX·전기료 / OPEX·상면비)으로 나눠 각각 색상 라벨
  (CAPEX=주황 `#FFB86C`, OPEX 3항목=시안 `#8BE9FD`, 기존 팔레트와 통일)과 모노스페이스 폰트로
  정리해서 보여줌. 각 항목 아래 원본에 있던 `※` 보충 설명(CAPEX 구성 요소, PUE 계산식)도 그대로
  캡션으로 표시. 배경 클릭 또는 × 버튼으로 닫힘.

