# v6.42

- Preserve active/running run history across platform upgrades or restarts instead of converting active runs to stopped.
- Change Docker image ensure order to local fallback tar load first, then docker pull with Docker proxy/daemon config refresh on pull failure.
- Apply fallback-first image handling to MLPerf training/inference, vLLM single instance, PD disaggregation, and llm-d deploy image preparation paths.
