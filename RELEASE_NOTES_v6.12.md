# poc-platform v6.12

## 변경 요약
- Dashboard 필터를 테스트 탭의 선택 체계와 맞춤: category → 테스트 종류 → version/model/env/mode.
- Dashboard 최근 실행 KIND 칩 색상을 테스트 종류별로 구분.
- 최근 실행 상세의 중복 대시보드 반영 버튼 제거, 행 버튼에 그라데이션 적용.
- 테스트 탭 결과/상태 색상에서 Running 계열을 보라색, Success를 초록색으로 통일.
- Run History/최근 실행 상세 parsed metric에서 hostname 중복 표시 제거.
- K8s Training Job의 /dev/shm emptyDir 기본 sizeLimit을 64Gi로 설정.
