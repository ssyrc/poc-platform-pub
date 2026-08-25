# v6.54

- Fixed vLLM Single Instance bench container argument assembly.
- `vllm bench serve` dataset flags are now written into a mounted bench script instead of being expanded inside the `docker run` command string.
- Prevents Docker from misinterpreting benchmark flags such as `--dataset-name` as local volume names.
