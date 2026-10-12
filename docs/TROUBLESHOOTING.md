# Troubleshooting

Start with `./doctor.sh`; it re-runs every installer check. Installer logs are in `build/logs/`, one file per stage or SQL file.

| Symptom | Cause | Fix |
|---|---|---|
| Preflight: `model X not callable` | Model not in your region | Accept the cross-region prompt, or change `*_MODEL` in `config/demo.env` |
| Preflight: database `<PREFIX>_MIRROR` exists | Mirror target databases cannot be reused, even after a mirror is dropped | Use a new `PREFIX` |
| `postgres` stage waits a long time | New instances take 5 to 15 minutes | The installer waits up to 20 minutes; rerun `--from postgres` if it times out |
| `pgschema`: connection timeout or SSL error | The network policy has not propagated yet (up to 2 minutes), or the CA secret is missing | Wait, then `./install.sh --from pgschema`; `./doctor.sh` lists the secrets |
| `pgschema`: a test FAILs | A governance control regressed | Read `build/logs/pg_tests.log` (every result line names the check); do not skip the stage |
| `images`: push denied | Registry login expired | `snow spcs image-registry login -c <connection>`, then `--from images` |
| `images`: build fails on Apple Silicon | buildx missing | Install Docker Desktop 4.x or enable buildx |
| Services stuck in PENDING | Pool still provisioning nodes | Wait 2 to 5 minutes; `SHOW COMPUTE POOLS LIKE '<PREFIX>_POOL'` |
| Agents claim breaks but never propose (escalated after 3 attempts) | Snowflake session token expired in a long-running container (fixed in this version by reconnecting) or model errors | `SELECT SYSTEM$GET_SERVICE_LOGS('<PREFIX>.APP.DESK_WORKER',0,'worker',200);` |
| Cards stuck on **QC hold** | Working as designed: QC caught a planted trap | Reject them, or run `./demo.sh close-day` |
| Dashboard numbers lag the live desk | Mirror refresh is 30 s; KPI cache is 15 s | Expected; the "Mirror lag" pill shows the lag |
| Mirror stops after `DROP SCHEMA desk` | Dropping the schema removes it from the publication | Use `./demo.sh reset`, which re-attaches it |
| App URL asks for sign-in, then 403 | User lacks the approver role | `GRANT ROLE <PREFIX>_APPROVER TO USER <user>;` |
| SPCS egress ranges change | Snowflake rotates published ranges (see `EGRESS_EXPIRES` in `build/vars.env`) | `./install.sh --from postgres` rebuilds the ingress rule |
