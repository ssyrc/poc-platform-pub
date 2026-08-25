# poc-platform v6.0.3

## UI updates
- 테스트 탭의 실시간 모니터링 그래프가 잘리지 않도록 모니터링 패널을 전체 폭 스택 구조로 변경했습니다.
- 결과 분석 패널을 실시간 모니터링과 Run History 사이에 배치했습니다.
- 결과 분석 패널 오른쪽에 로그 확인 영역을 추가하고, 실시간 모니터링 패널에서는 로그 표시를 제거했습니다.
- 결과 분석 하단 액션을 copy / report / 대시보드 반영 순서로 정렬했습니다.
- LOG PATH 텍스트는 UI에 직접 표시하지 않고 copy 버튼만 남겼습니다.
- log path 복사는 폴더 경로 끝에 /run.log를 붙인 경로를 사용합니다.
- 대시보드 반영 버튼은 성공 결과일 때만 활성화됩니다.
- Training / Inference 좌측 테스트 탭에 RUN / OK / ERR 상태 배지를 추가했습니다. 종료 상태 배지는 클릭하면 확인 처리되어 사라집니다.

## Verification
- backend/*.py py_compile
- scripts/*.sh and nested shell scripts bash -n
- frontend/app.jsx Babel transform
- frontend/index.html embedded JSX Babel transform
- zip integrity test
