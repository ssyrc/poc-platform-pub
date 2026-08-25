# poc-platform v3.5.26

## 변경 사항

- 테스트 클러스터 관리 > 클러스터 관리 탭의 노드 상세 정보 모달을 raw JSON 중심에서 파싱된 카드/표 형태로 개선.
- Warewulf 클러스터 모니터링 테이블의 열 너비를 조정해 hostname, connected/disconnected, 상세 정보 확인, 전원 관리 요청 버튼이 한 줄로 보이도록 개선.
- Training 테스트와 Inference 테스트의 서브 탭을 좌측 메뉴 하위에 표시하도록 추가.
- 설정 & 실행 헤더를 더 얇은 한 줄형 구조로 정리하고 Run 버튼이 같은 행에서 잘 보이도록 조정.
- 환경 선택 기본값을 Bare Metal로 변경하기 위해 Training MLPerf, Inference MLPerf, vLLM 설정 저장 키를 갱신.
- PoC Bench Platform 및 테스트 영역 아이콘 내부 SVG가 흰색으로 밝게 표시되도록 스타일 보정.

## 검증

- frontend/app.jsx Babel transform 확인.
- frontend/index.html embedded JSX Babel transform 확인.
- backend/*.py py_compile 확인.
- zip integrity test 확인.
