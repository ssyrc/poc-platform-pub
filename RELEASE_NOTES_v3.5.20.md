# v3.5.20

- Updated sidebar brand icon with a brighter AI infra style mark.
- Dashboard GPU Type filter now supports no visual selection while leaving results unfiltered.
- Renamed Dashboard export button to `Download Result` and removed the clear button.
- Renamed Cluster OS provisioning menu to `클러스터 관리`, Warewulf action card to `OS Provisioning`, and monitoring card to `클러스터 모니터링`.
- Added `<control-plane-host> (<control-plane-ip>)` as the Kubernetes master / Warewulf manager monitoring target.
- Updated Training/Inference GPU node status chips to `wwctl O/X` and `k8s O/X` with success/error coloring.
- Added an info tooltip to GPU node settings explaining where to verify Warewulf and K8s worker registration.
