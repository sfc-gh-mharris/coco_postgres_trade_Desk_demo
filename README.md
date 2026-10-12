# Governed T+1 Trade-Break Desk on Snowflake

A working demo of AI agents that triage T+1 settlement breaks under hard governance controls, built only on Snowflake.

- **Snowflake Postgres** holds the work queue, leases, fence tokens and an append-only ledger. `LISTEN/NOTIFY` wakes agents in milliseconds.
- **Snowpark Container Services** runs the agents:
  - investigator agents built on the Cortex Code Agent SDK
  - an independent QC agent
  - a deterministic executor
  - the human approval UI
- **Postgres-to-Snowflake mirroring** feeds a live dashboard, a permanent audit archive, and the `DESK_FLIGHT_RECORDER` Cortex Agent in Snowflake Intelligence / CoWork.

Two approval UIs are included; install either or both:

| UI | What it is |
|---|---|
| `streamlit` | Streamlit console: approval queue, agent controls, KPIs |
| `node` | Node.js command center: live approval cards, agent activity, mirror dashboard, "Add breaks", "Approve all eligible", "Close day" |

## Quickstart

```bash
git clone https://github.com/sfc-gh-mharris/coco_postgres_trade_Desk_demo.git
cd coco_postgres_trade_Desk_demo
./install.sh            # first run creates config/demo.env, then exits
$EDITOR config/demo.env # set SNOW_CONNECTION, PREFIX, UI
./install.sh            # about 25-40 minutes, mostly waiting on Postgres and image builds
```

The installer:
- checks prerequisites before creating anything
- verifies every stage after applying it
- stops with the reason and a fix if something is wrong
- resumes where it left off (`./install.sh --from <stage>`)

At the end it prints the app URLs.

**Using Cortex Code?** Open the cloned folder and say **"install the break desk demo"**. The project skill in `.snowflake/cortex/skills/` is auto-discovered and drives the same scripts.
Without a clone, add it in CoCo: Agent Settings → Skills → **Add from GitHub** → `https://github.com/sfc-gh-mharris/coco_postgres_trade_Desk_demo/tree/main/skills`. The skill clones the repo for you.

## Prerequisites

| Requirement | Why | Checked by preflight |
|---|---|---|
| Snowflake account on **AWS or Azure**, not a trial | Postgres mirroring and SPCS | yes |
| A user with **ACCOUNTADMIN** | creates the Postgres instance, integrations and roles | yes |
| Snowflake Postgres available on the account | the queue | yes |
| Cortex models (defaults: `gemini-3.8-flash`, `claude-haiku-4-5`, `claude-opus-5-5`) | agents and flight recorder | yes; offers to enable cross-region inference |
| Snowflake CLI 3.x with a working connection | runs everything | yes |
| Docker with buildx (linux/amd64) | builds 2 images locally | yes |
| python3 | templating and checks | yes |

You do **not** need to create the Postgres instance, the mirror, secrets or network rules. The installer creates all of them, and Postgres passwords never leave Snowflake secrets. To reuse an existing instance instead, see [docs/INSTALL.md](docs/INSTALL.md#reusing-an-existing-postgres-instance).

## Operate

```bash
./doctor.sh                     # re-run every check
./demo.sh status                # services, queue, URLs
./demo.sh seed 10               # replay 10 DEMO breaks at 1/s
./demo.sh close-day             # end-of-day roll: open breaks to exceptions, actions expire
./demo.sh canary on|off         # staged regression for the QC demo
./demo.sh pause | resume        # stop/start billing between demos
./uninstall.sh                  # remove everything for this PREFIX
```

## Docs

- [docs/INSTALL.md](docs/INSTALL.md): stages, config, what gets created, existing-instance mode.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): components, data flow, governance controls.
- [docs/DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md): a 15-minute run-through for either UI.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): common failures and fixes.
- [docs/SPCS_CORTEX_CODE_BEST_PRACTICES.md](docs/SPCS_CORTEX_CODE_BEST_PRACTICES.md): running the Cortex Code CLI and SDK in SPCS (auth, tokens, Dockerfile, SDK patterns).

## Cost

While resumed, the demo uses:
- 1 to 3 `CPU_X64_S` SPCS nodes
- one `STANDARD_M` Postgres instance
- an XS warehouse that auto-suspends after 60 s
- serverless mirror refreshes
- Cortex tokens per break (about 0.2k output tokens per investigation)

Run `./demo.sh pause` when you are not demoing; only storage is billed while paused.
