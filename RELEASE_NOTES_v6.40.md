# v6.40

- Training 로그 확인에서 hostname 선택 시 해당 host 로그만 표시되도록 필터링을 강화했습니다.
- host-local fatal platform message를 해당 hostname에 귀속시켜 다른 host 선택 화면에 섞이지 않게 했습니다.
- 새 Run 시작 시 기존 로그, 실시간 GPU 모니터링 데이터, EventSource 스트림을 모두 초기화하도록 수정했습니다.
- GPU live stream replay 옵션을 추가하고 새 Run에서는 이전 host 샘플 replay를 끄도록 수정했습니다.
- Training Precision에서 NeMo PEFT LoRA 경로에서 실패하던 legacy FP16/16/16-true 입력을 명시적 FP16 mixed precision인 16-mixed로 정규화했습니다.
