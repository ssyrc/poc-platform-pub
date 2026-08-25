# v6.59

- Fixed blank screen caused by stale duplicate inline React app in `frontend/index.html`.
- Kept dashboard API persistence from v6.58 and ensured the inline HTML bundle exposes `api.getDashboard()` / `api.saveDashboard()` consistently.
