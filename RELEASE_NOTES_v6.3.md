# RELEASE NOTES v6.3

- 로그 확인 패널의 LOG PATH 표시를 실제 경로 중심으로 변경하고 copy 버튼만 유지했습니다.
- Report 다운로드 버튼을 결과 확인 패널의 대시보드 반영 버튼 왼쪽으로 이동했습니다.
- Training Bare Metal 세부 파라미터에서 호스트별 CUDA_VISIBLE_DEVICES 직접 지정을 지원합니다.
- Inference vLLM Bare Metal 세부 파라미터에서 호스트별 CUDA_VISIBLE_DEVICES 직접 지정을 지원합니다.
- CUDA_VISIBLE_DEVICES를 비워두면 기존처럼 현재 free GPU 순서대로 자동 선택합니다.
