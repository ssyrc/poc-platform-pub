# v6.49

- Run History / Recent 실행 삭제 확인 모달을 React portal로 렌더링해 현재 viewport 중앙에 표시되도록 수정했습니다.
- MLPerf Inference v5.1/v6.0 container 내부 non-root 전환을 `su`에서 passwordless UID/GID 전환(`setpriv`, fallback `runuser`) 방식으로 변경했습니다.
- NVIDIA device/socket gid를 docker `--group-add`로 전달해 non-root 사용자도 GPU device에 접근할 수 있도록 보강했습니다.
- MLPerf Inference v6.0에서 host driver가 590 미만이면 기존 TensorRT-LLM v6.0 image 대신 driver-560 환경용 compatible MLPerf image를 기본 선택하도록 변경했습니다. 사용자가 `--docker-image`를 지정하면 override를 우선합니다.
- Dashboard line/scatter/bar series는 all versions/models/environments 선택 시 GPU type만으로 연결하지 않고, version/model/environment/mode scope를 자동 group key에 포함해 legend를 분리합니다.
