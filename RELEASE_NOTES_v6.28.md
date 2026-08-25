# poc-platform v6.28

- Dashboard Pinned Data 테이블 열 순서를 `{groups 설정값}, num_gpus, model, {x axis 설정값}, {y axis 설정값}, 실험 세팅 확인, 결과 확인, log path, start time` 기준으로 재정렬했습니다.
- Dashboard chart의 legend가 더 이상 GPU type에 고정되지 않고, `groups` 선택값 기준으로 표시되도록 수정했습니다.
- `groups` 선택에 맞춰 Pinned Data 첫 번째 열도 동적으로 바뀌도록 수정했습니다.
- 그래프 point 클릭 시 대응되는 Pinned Data 행이 하이라이트되고, Pinned Data 행 클릭 시 대응되는 그래프 point가 하이라이트되도록 연동했습니다.
- Pinned Data 테이블 UI를 pill/selected-row 스타일로 정리했습니다.
