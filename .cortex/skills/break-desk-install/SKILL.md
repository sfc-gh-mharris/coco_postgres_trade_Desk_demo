---
name: break-desk-install
description: Install, check, operate, or remove the governed T+1 trade-break desk demo (Snowflake Postgres + mirror + SPCS agents + Streamlit/Node approval UI) in the user's Snowflake account. Triggers - install the break desk demo, set up the trade desk demo, deploy break desk, break desk doctor, pause the break desk, uninstall break desk.
---

# Break Desk demo: install and operate

All logic lives in the repo scripts. Never re-implement steps by hand; run the scripts and act on their output.

## Install

1. Confirm the user is in the repo root (`install.sh` exists).
2. If `config/demo.env` is missing, run `./install.sh` once (it copies the example), then ask the user, with ask_user_question:
   - Which Snowflake connection to use. Show the names from `snow connection list`.
   - Which UI: `streamlit`, `node` or `both`.
   - The PREFIX (default `BREAK_DESK`), and any extra approver users.
   Write the answers into `config/demo.env`.
3. Run `./install.sh` in the background and poll its output. It is resumable; each stage prints `[ok]`/`[fail]`.
4. If it stops (`[stopped]`), read the reason and the `->` hints, plus the log file it names in `build/logs/`. Fix the cause (config value, Docker not running, model availability), then run `./install.sh --from <stage>`.
   - It may ask about cross-region inference or reusing an existing database. Relay that question to the user; do not answer it for them.
5. On success, give the user the printed URLs and point to `docs/DEMO_SCRIPT.md`.

## Operate

- **Health:** `./doctor.sh`.
- **Day of demo:** `./demo.sh status | seed 10 | close-day | canary on|off | reset | pause | resume`.
- **Remove:** `./uninstall.sh`. It lists everything first; confirm with the user before passing `--yes`.

## Rules

- Do not print or copy Postgres passwords; the installer keeps them inside Snowflake secrets.
- Do not edit `sql/` templates to work around a failing check; report the failure instead.
