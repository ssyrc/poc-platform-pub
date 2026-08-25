# poc-platform v6.16

- Dashboard pinned data is enriched from persisted run history by run_id, so legacy pinned records recover version/model/env metadata.
- Dashboard version filtering now uses the recovered version instead of showing version-less records in every version.
- Dashboard category selector is rendered as two stacked buttons.
- Training dashboard defaults are fixed to x=Max steps, y=Validation accuracy, groups=Gpu type.
- Recent Runs table now includes Test Settings between KIND and STATUS.
- Run History GPU charts reset and reload per selected run so each history item shows its own monitoring samples.
