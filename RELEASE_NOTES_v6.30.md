# poc-platform v6.30

## 변경 사항

- GPU type 자동 탐지 로직을 보강했습니다.
- NVIDIA 탐지는 `nvidia-smi --query-gpu=name --format=csv,noheader`를 우선 사용합니다.
- query 방식이 실패하면 `nvidia-smi -L`로 fallback합니다.
- 마지막으로 일반 `nvidia-smi` 출력에서 NVIDIA GPU product name을 best-effort로 파싱합니다.
- A100/GH200/RTX PRO 6000/B200/B300 계열에서도 `--format` 누락 문제로 GPU type이 H100 fallback 되는 상황을 줄였습니다.

## 실행

```bash
unzip poc-platform-v6.30.zip
cd poc-platform-v6.30
chmod +x start_platform.sh scripts/*.sh scripts/*/*.sh scripts/training/*.sh
./start_platform.sh
```
