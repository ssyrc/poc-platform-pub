# poc-platform v6.0.4

## 변경 사항

- 테스트 탭 GPU 노드 설정에서 hostname 입력 시 `nvidia-smi` 기반 사용 가능 GPU 수를 표시합니다.
- Bare Metal 실행 시 설정한 GPU 수만큼 프로세스가 없는 GPU index를 자동 선택해 실행합니다.
  - MLPerf Training / Inference: `MLPERF_CUDA_VISIBLE_DEVICES`로 전달
  - vLLM Single Instance / Ray: `--gpu-map host=...` 전달 후 serve 컨테이너에 적용
  - PD Disaggregation: Prefill/Decode 각 host별 `--gpu-map host=...` 적용
- 추가된 노드 카드에서 hostname과 GPU 수량을 직접 수정할 수 있게 했습니다.
- 추가된 노드는 카드가 전체 가로 폭을 차지하지 않고, 필요한 너비만 사용하며 오른쪽으로 이어지고 줄바꿈됩니다.
- 노드 카드 목록은 카드 영역 내부에서 스크롤됩니다.

## 검증

- `python -m py_compile backend/*.py`
- `bash -n scripts/*.sh scripts/*/*.sh`
- `frontend/app.jsx` Babel transform
- `frontend/index.html` embedded JSX Babel transform
- `zip -T`
