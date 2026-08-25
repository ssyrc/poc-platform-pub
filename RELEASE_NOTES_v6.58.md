# v6.58

- Dashboard typography: removed heavy/bold overrides from Pinned Data and Recent Runs action text while preserving readable UI font family.
- Pinned Data graph selection: defaults to all visible pinned rows and keeps new rows selected when the previous visible set was fully selected.
- Dashboard persistence: added backend-backed `/api/dashboard` storage in `.poc_platform_state/dashboard.json` so pinned dashboard data survives platform version upgrades beyond browser localStorage.
