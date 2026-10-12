# Install guide

## Configuration (`config/demo.env`)

| Key | Default | Notes |
|---|---|---|
| `SNOW_CONNECTION` | `default` | Name from `snow connection list`. The user needs ACCOUNTADMIN. |
| `PREFIX` | `BREAK_DESK` | Every object name derives from it, so two installs can share an account. |
| `UI` | `both` | `streamlit`, `node` or `both`. Add the other UI later with `./install.sh --from ui --ui node`. |
| `APPROVER_USERS` | empty | Extra users to grant the approver role. The installing user always gets it. |
| `PG_MODE` | `create` | `create` (recommended) or `existing`. |
| `PG_INSTANCE` | `<prefix>_pg` | Instance name. For `existing`, set it to the instance to reuse. |
| `PG_COMPUTE_FAMILY` / `PG_STORAGE_GB` | `STANDARD_M` / `50` | `BURST_*` is not supported for mirroring. |
| `MIRROR_REFRESH` | `30 seconds` | Mirror merge cadence. |
| `POOL_INSTANCE_FAMILY` / `POOL_MAX_NODES` | `CPU_X64_S` / `3` | The agents need 3 nodes at peak. |
| `*_MODEL` | see file | Preflight calls each model once. |
| `CROSS_REGION_OFFER` | `ANY_REGION` | Value offered for `CORTEX_ENABLED_CROSS_REGION` if a model is unavailable in-region. The installer asks before changing it. |

## Objects created (for `PREFIX=BREAK_DESK`)

| Kind | Name |
|---|---|
| Database | `BREAK_DESK` (schemas `REF`, `APP`, `AUDIT`) |
| Mirror target database | `BREAK_DESK_MIRROR` (created by `CREATE_MIRROR`; must not exist beforehand) |
| Warehouse | `BREAK_DESK_WH` (XS, 60 s auto-suspend) |
| Compute pool | `BREAK_DESK_POOL` |
| Postgres instance | `break_desk_pg`, with network policy `BREAK_DESK_PG_POLICY` |
| External access integration | `BREAK_DESK_PG_EAI` |
| Roles | `BREAK_DESK_SERVICE_ROLE`, `BREAK_DESK_AGENT_ROLE`, `BREAK_DESK_COMMAND_ROLE`, `BREAK_DESK_APPROVER` |
| Secrets | `PG_ADMIN_SECRET`, `PG_CA_SECRET`, plus one per desk login (`desk_app`, `desk_qc`, `desk_exec`, `desk_approver_svc`, `desk_sim`) |
| Services | `DESK_WORKER` (x2), `DESK_WORKER_CANARY`, `DESK_QC`, `DESK_EXECUTOR`, `DESK_CONSOLE` and/or `DESK_COMMAND` |
| Audit | archive tables, `ARCHIVE_DESK_TASK` (5 min), semantic view `DESK_AUDIT_SV`, agent `DESK_FLIGHT_RECORDER` |

## Stages

`./install.sh` runs these in order. Each one applies its changes, then verifies them. Completed stages are recorded in `build/state/`.

| Stage | Does | Verifies |
|---|---|---|
| `preflight` | Checks tools, the connection and ACCOUNTADMIN, the cloud, Postgres and SPCS availability, the egress ranges, models (offers cross-region), and name collisions. | stops before creating anything |
| `foundation` | Creates the database, schemas, warehouse, image repo, SQL stage, compute pool, the 4 roles and their grants. | every object exists |
| `postgres` | Creates the instance and waits for READY. Stores the CA certificate as a secret. Sets up the egress rule and EAI, and the ingress policy built from `SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES`. Rotates the admin password into a secret and generates the 5 login secrets. | instance READY; secrets, EAI and policy exist; the agent role can read its secrets |
| `images` | Logs in to the registry, then builds and pushes `desk-agents:<VERSION>` (and `desk-command` if the Node UI is selected). | images and tags are in the repository |
| `refdata` | Generates deterministic reference data and break scenarios dated relative to install day. | 500/10/10 scenarios; agents can call `TRADE_EVIDENCE()`; agents **cannot** read ground truth |
| `pgschema` | Applies the desk schema and runs the 30 governance tests, each as the Postgres login that would attempt the action. Then rebuilds a clean schema. | 30/30 PASS |
| `mirror` | `CREATE_MIRROR` of schema `desk`, plus read grants for the Node app. | all 9 tables REPLICATING |
| `agents` | Investigators, canary, QC and executor; then a smoke-test break. | services READY; the break gets an agent proposal |
| `audit` | Archive tables and task, semantic view, flight recorder agent, approver grants. | task, view and agent exist |
| `ui` | The chosen UI(s), their service-role grants, and public endpoints. | services READY; URLs printed |

Useful flags:
- `--from <stage>` re-runs from a stage.
- `--only <stage>` runs one stage.
- `--yes` accepts the defaults.
- `--ui node|streamlit|both` overrides the UI setting.

## Credentials and security

- **Admin password.** `snowflake_admin` is rotated with `ALTER POSTGRES INSTANCE ... RESET ACCESS` inside a Snowflake Scripting block and written straight into `PG_ADMIN_SECRET`. It is never returned, printed or written to disk. The one-time credentials from `CREATE POSTGRES INSTANCE` are discarded.
- **Desk login passwords.** These are generated with `RANDSTR` inside Snowflake. Containers receive them as mounted secrets.
- **CA certificate.** It is public and per-account. It is stored as a `GENERIC_STRING` secret and mounted at `/secrets/pg_ca`. Postgres connections use `sslmode=verify-full`.
- **Postgres network access.** Postgres admits only Snowflake's published SPCS egress ranges. Your laptop does not connect to Postgres; all Postgres work runs in SPCS jobs.

## Reusing an existing Postgres instance

1. Set `PG_MODE=existing` and `PG_INSTANCE=<name>` in `config/demo.env`. The instance must be on STANDARD or HIGHMEM, and have no mirror targeting `<PREFIX>_MIRROR`.
2. Run `./install.sh`. It stops at the `postgres` stage and asks you to create the admin secret. In Snowsight:
   ```sql
   CREATE SECRET <PREFIX>.APP.PG_ADMIN_SECRET TYPE = PASSWORD
     USERNAME = 'snowflake_admin' PASSWORD = '<snowflake_admin password>';
   ```
3. Run `./install.sh --from postgres`.

The installer **replaces** the instance's network policy with one that admits SPCS only. If other clients use the instance, add their rules to `<PREFIX>_PG_POLICY` afterwards. `uninstall.sh` never drops an existing instance.

## Re-installing and upgrading

- After pulling a new version, bump `VERSION` (or keep it) and run `./install.sh --from images`. Services are upgraded in place with `ALTER SERVICE ... FROM SPECIFICATION`, so endpoint URLs do not change.
- `./demo.sh reset` rebuilds an empty Postgres desk schema and re-attaches it to the mirror. The Snowflake audit archive keeps every run.
