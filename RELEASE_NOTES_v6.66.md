# v6.66

- GitHub 공개 저장소 초기 import를 위해 site-specific 보안 정보를 코드에서 분리했습니다.
- Warewulf/Kubernetes endpoint, registry credential, Docker proxy/registry 설정, 사용자별 데이터 경로를 `.env` 기반 설정으로 변경했습니다.
- `.env`는 Git에서 제외하고 `.env.example`만 제공합니다.
- Docker registry password는 더 이상 source/remote command에 하드코딩하지 않으며, controller의 `.env`에서 읽어 Docker host bootstrap의 SSH stdin으로 전달합니다.
- frontend의 특정 사내 hostname/IP 기본값을 runtime metadata 또는 일반 예시값으로 변경했습니다.
- `frontend/app.jsx`와 `frontend/index.html` inline JSX를 동기화했습니다.
