---
name: break-desk-install
description: Install, verify, operate, or remove the governed T+1 trade-break desk demo (Snowflake Postgres + mirror + SPCS Cortex Code agents + Streamlit/Node approval UI) in the user's own Snowflake account, using the repo's install.sh. Triggers - install the break desk demo, set up the trade desk demo, deploy break desk, trade break agent demo, break desk doctor, seed breaks, close the desk day, pause the break desk, uninstall break desk.
---

# Break Desk demo: install and operate

Repo: https://github.com/sfc-gh-mharris/coco_postgres_trade_Desk_demo

**Ground rule:** all logic lives in the repo scripts. Never recreate steps by hand with ad-hoc SQL. Run the scripts, read their output, and fix the cause they report.

## 0. Get the repo

If the current folder has no `install.sh`, ask the user where to put the clone, then:

```bash
git clone https://github.com/sfc-gh-mharris/coco_postgres_trade_Desk_demo.git
cd coco_postgres_trade_Desk_demo
```

## 1. Configure (ask, don't guess)

1. Run `./install.sh` once. If `config/demo.env` does not exist, it copies the example and exits.
2. Run `snow connection list`, then ask the user in a single ask_user_question:
   - **Connection:** which connection to use. Its user needs ACCOUNTADMIN on an AWS or Azure, non-trial account.
   - **UI:** `streamlit`, `node` or `both` (default `both`).
   - **PREFIX:** default `BREAK_DESK`. Use another if that database already exists, for example `BREAK_DESK_<INITIALS>`.
   - **Approvers:** any extra users who should get the approver role.
3. Write the answers into `config/demo.env` (`SNOW_CONNECTION`, `UI`, `PREFIX`, `APPROVER_USERS`).
   - Quote values that contain spaces, for example `MIRROR_REFRESH="30 seconds"`.

## 2. Preflight first, in the foreground

```bash
./install.sh --only preflight --yes
```

Before using `--yes`, set `CROSS_REGION_OFFER=NONE` in `config/demo.env`, so `--yes` cannot change an account setting on its own.

**If preflight reports `model X not callable`:** ask the user whether to enable cross-region inference. It is an account-wide setting.
- **If yes:** set `CROSS_REGION_OFFER=ANY_REGION` and re-run preflight.
- **If no:** ask which model to use instead, and update `INVESTIGATOR_MODEL`, `QC_MODEL` and the other model settings.

**If preflight stops on a name collision:** ask the user for a new PREFIX. Never drop their objects.

## 3. Install, in the background

```bash
./install.sh --yes > build/install.log 2>&1   # 25-40 min: Postgres creation + image builds dominate
```

- **Docker must be running.** The installer builds two `linux/amd64` images locally.
- **Monitoring:** poll `build/install.log` every 2–4 minutes. Each stage prints `[ok]` or `[fail]`.
- **Progress for the user:** report it at stage boundaries:
  preflight → foundation → postgres → images → refdata → pgschema → mirror → agents → audit → ui.
- **On `[stopped]`:** read the reason, the `->` hints, and the log file it names in `build/logs/`.
  - Fix the cause: a config value, Docker, registry login, or a model.
  - Then resume with `./install.sh --yes --from <stage>`. Completed stages are skipped.

Expected checks you can quote:
- governance tests `30/30 PASS`
- mirror `9/9 tables REPLICATING`
- smoke test `agent proposed: ...`
- the URLs at the end

## 4. Hand-off

- Give the user the Streamlit and/or Node URLs.
- They sign in with Snowflake SSO. The approver role is already granted to the installing user.
- Point them to `docs/DEMO_SCRIPT.md`.
- Suggest `./demo.sh pause` when they are done, to save cost.

## Operate

| Need | Command |
|---|---|
| Health check (read-only) | `./doctor.sh` |
| Status and URLs | `./demo.sh status` |
| Add breaks | `./demo.sh seed 10` (or `seed 10 2 QC` for the QC-trap batch) |
| Clean slate / next day | `./demo.sh close-day --yes` |
| Canary regression demo | `./demo.sh canary on`, later `./demo.sh canary off` |
| Hold executor (kill-switch demo) | `./demo.sh executor pause`, later `./demo.sh executor resume` |
| Empty the desk | `./demo.sh reset --yes` (keeps the Snowflake audit archive) |
| Stop or start billing | `./demo.sh pause` / `./demo.sh resume` |
| Add the other UI later | `./install.sh --yes --from ui --ui node` |
| Remove everything | `./uninstall.sh`. Show the user its list, and pass `--yes` only after they confirm. |

## Rules

- Never print, echo or copy Postgres passwords or secret values. The installer keeps them inside Snowflake secrets.
- Do not edit `sql/` templates or skip a stage to get past a failing check. Report the failure and its log line.
- Ask before anything account-wide or destructive: cross-region inference, reusing an existing database or Postgres instance, `reset`, `uninstall`.
- When checking role access by hand, prefix SQL with `USE SECONDARY ROLES NONE; USE WAREHOUSE <PREFIX>_WH;`. Otherwise the user's secondary roles hide permission problems.
- More context: `docs/INSTALL.md`, `docs/TROUBLESHOOTING.md`, `docs/ARCHITECTURE.md`, `docs/SPCS_CORTEX_CODE_BEST_PRACTICES.md`.
