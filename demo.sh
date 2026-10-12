#!/usr/bin/env bash
# Day-of-demo controls.
#   ./demo.sh status            services, queue, URLs
#   ./demo.sh seed [N] [RATE] [BATCH]   replay N breaks (default 10 DEMO) at RATE/s (default 1); BATCH=DEMO|QC|EVAL
#   ./demo.sh close-day         end-of-day: escalate open breaks, expire open actions (nothing deleted)
#   ./demo.sh reset             rebuild an empty desk schema (wipes Postgres desk data; archive kept)
#   ./demo.sh canary on|off     enable/disable the staged-regression canary (investigator-v3)
#   ./demo.sh executor pause|resume   hold the executor (for the approve-then-kill demo)
#   ./demo.sh pause | resume    stop/start billing: services, pool, Postgres instance
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. scripts/lib/common.sh
. scripts/lib/checks.sh
load_config; recall; write_vars
args=(); for a in "$@"; do case "$a" in --yes|-y) ASSUME_YES=1;; *) args+=("$a");; esac; done
set -- "${args[@]+"${args[@]}"}"
cmd="${1:-status}"; shift || true

AGENT_SVCS="DESK_WORKER DESK_WORKER_CANARY DESK_QC"
ui_svcs() {  # role:service pairs for the deployed UIs
  [ "$UI" != node ] && echo "$SERVICE_ROLE:DESK_CONSOLE"
  [ "$UI" != streamlit ] && echo "$COMMAND_ROLE:DESK_COMMAND"
  return 0
}

pg_sql() {  # pg_sql <tag> <login> <sql>
  printf '%s\n' "$3" > "$BUILD/sql/demo_$1.sql"
  pg_job "$1" "$BUILD/sql/demo_$1.sql@$2" || die "Postgres job failed" "See $LOGS/pg_$1.log"
  grep '^SQLRUN_RESULT' "$LOGS/pg_$1.log" | sed 's/^SQLRUN_RESULT [0-9]* /   /'
}

case "$cmd" in
  status)
    step "Services"
    for s in $AGENT_SVCS; do info "$s: $(service_status "$AGENT_ROLE" "$s")"; done
    info "DESK_EXECUTOR: $(service_status "$SERVICE_ROLE" DESK_EXECUTOR)"
    for p in $(ui_svcs); do info "${p#*:}: $(service_status "${p%%:*}" "${p#*:}")"; done
    step "Queue (mirror \$LIVE)"
    q=$(sf_json ACCOUNTADMIN "SELECT STATUS, COUNT(*) N FROM $MIRROR_DB.DESK.\"BREAKS\$LIVE\" GROUP BY 1 ORDER BY 1")
    info "$(json_get "$q" "', '.join(f\"{x['STATUS']} {x['N']}\" for x in r) or 'empty'")"
    step "URLs"
    info "Streamlit: ${CONSOLE_URL:-n/a}"; info "Node:      ${COMMAND_URL:-n/a}"
    ;;
  seed)
    n="${1:-10}"; rate="${2:-1}"; batch="${3:-DEMO}"; name="SIM_$(date +%s)"
    case "$batch" in DEMO|QC|EVAL) ;; *) die "BATCH must be DEMO, QC or EVAL";; esac
    step "Replaying $n $batch breaks at $rate/s"
    cat > "$BUILD/sql/sim_job.sql" <<EOF
EXECUTE JOB SERVICE IN COMPUTE POOL $POOL NAME = $DB.APP.$name
  EXTERNAL_ACCESS_INTEGRATIONS = ($EAI) QUERY_WAREHOUSE = $WH
  FROM SPECIFICATION \$\$
spec:
  containers:
  - name: sim
    image: $REPO_PATH/desk-agents:$VERSION
    args: ["sim.py"]
    env: {PGHOST: $PG_HOST, DESK_DB: $DB, BATCH: $batch, LIMIT: "$n", RATE_PER_S: "$rate", ID_SUFFIX: "-S$(date +%H%M%S)", SNOWFLAKE_WAREHOUSE: $WH}
    secrets:
    - {snowflakeSecret: $DB.APP.PG_SIM_SECRET, directoryPath: /secrets/pg}
    - {snowflakeSecret: $DB.APP.PG_CA_SECRET, directoryPath: /secrets/pg_ca}
    sessionTokenConfig: {mountConnectionConfig: true}
\$\$;
EOF
    SNOW --role "$SERVICE_ROLE" -f "$BUILD/sql/sim_job.sql" > "$LOGS/sim.log" 2>&1
    service_logs "$SERVICE_ROLE" "$name" sim 500 | grep -E "SIM_RESULT|Error" || warn "no simulator output (see $LOGS/sim.log)"
    SNOW --role "$SERVICE_ROLE" -q "DROP SERVICE IF EXISTS $DB.APP.$name" >/dev/null 2>&1
    ;;
  close-day)
    ask "Close the desk day (open breaks -> ESCALATED, open actions -> EXPIRED)" || exit 0
    pg_sql close desk_approver_svc "SELECT desk.close_desk_day('$INSTALL_USER (demo.sh)', 'demo.sh close-day') AS summary;"
    ;;
  reset)
    ask "Wipe the Postgres desk schema and rebuild it empty (the Snowflake audit archive is kept)" || exit 0
    for s in $AGENT_SVCS; do sf_q "$AGENT_ROLE" "ALTER SERVICE $DB.APP.$s SUSPEND"; done
    sf_q "$SERVICE_ROLE" "ALTER SERVICE $DB.APP.DESK_EXECUTOR SUSPEND"
    pg_job reset "$(render sql/postgres/desk_schema.sql)@pg_admin" "$(render sql/postgres/desk_command.sql)@pg_admin" \
      || die "Schema rebuild failed" "See $LOGS/pg_reset.log"
    # Dropping the schema removes it from the mirror publication; add it back.
    sf_q ACCOUNTADMIN "CALL SNOWFLAKE.POSTGRES.ALTER_MIRROR(mirror_name => '$MIRROR_NAME', add_schemas => ['desk'])" \
      && ok "mirror re-attached" || warn "ALTER_MIRROR failed; run ./doctor.sh"
    for s in $AGENT_SVCS; do sf_q "$AGENT_ROLE" "ALTER SERVICE $DB.APP.$s RESUME"; done
    sf_q "$SERVICE_ROLE" "ALTER SERVICE $DB.APP.DESK_EXECUTOR RESUME"
    ok "desk reset; agents resuming"
    ;;
  canary)
    en=false; [ "${1:-}" = on ] && en=true
    if [ $en = true ]; then
      # Canary on: route new work to the loose v3 prompt only, so QC has something to catch.
      pg_sql canary desk_approver_svc "SELECT desk.set_agent_control('investigator-v1', false, '$INSTALL_USER (demo.sh)') AS v1,
        desk.set_agent_control('investigator-v3', true, '$INSTALL_USER (demo.sh)') AS v3;"
    else
      pg_sql canary desk_approver_svc "SELECT desk.set_agent_control('investigator-v3', false, '$INSTALL_USER (demo.sh)') AS v3,
        desk.set_agent_control('investigator-v1', true, '$INSTALL_USER (demo.sh)') AS v1;"
    fi
    ;;
  executor)
    case "${1:-}" in
      pause) sf_q "$SERVICE_ROLE" "ALTER SERVICE $DB.APP.DESK_EXECUTOR SUSPEND" && ok "executor suspended (approved actions wait)";;
      resume) sf_q "$SERVICE_ROLE" "ALTER SERVICE $DB.APP.DESK_EXECUTOR RESUME" && ok "executor resuming";;
      *) die "usage: ./demo.sh executor pause|resume";;
    esac
    ;;
  pause)
    step "Pausing (storage still billed)"
    for p in $(ui_svcs); do sf_q "${p%%:*}" "ALTER SERVICE $DB.APP.${p#*:} SUSPEND" && ok "${p#*:} suspended"; done
    for s in $AGENT_SVCS; do sf_q "$AGENT_ROLE" "ALTER SERVICE $DB.APP.$s SUSPEND" && ok "$s suspended"; done
    sf_q "$SERVICE_ROLE" "ALTER SERVICE $DB.APP.DESK_EXECUTOR SUSPEND" && ok "DESK_EXECUTOR suspended"
    sf_q ACCOUNTADMIN "ALTER COMPUTE POOL $POOL SUSPEND" && ok "pool suspended"
    sf_q ACCOUNTADMIN "CALL SNOWFLAKE.POSTGRES.SUSPEND_MIRROR('$MIRROR_NAME')" && ok "mirror suspended"
    sf_q ACCOUNTADMIN "ALTER TASK $DB.AUDIT.ARCHIVE_DESK_TASK SUSPEND" && ok "archive task suspended"
    sf_q ACCOUNTADMIN "ALTER POSTGRES INSTANCE \"$PG_INSTANCE\" SUSPEND" && ok "Postgres suspended"
    ;;
  resume)
    step "Resuming"
    sf_q ACCOUNTADMIN "ALTER POSTGRES INSTANCE \"$PG_INSTANCE\" RESUME" && ok "Postgres resuming"
    t=0; while [ $t -lt 900 ]; do
      st=$(sf_json ACCOUNTADMIN "SHOW POSTGRES INSTANCES LIKE '$PG_INSTANCE'" | json_get "$(cat)" "r[0]['state'] if r else ''")
      [ "$st" = READY ] && break; sleep 15; t=$((t + 15))
    done
    ok "Postgres $st"
    sf_q ACCOUNTADMIN "CALL SNOWFLAKE.POSTGRES.RESUME_MIRROR('$MIRROR_NAME')" && ok "mirror resumed" || warn "mirror resume failed; see ./doctor.sh"
    sf_q ACCOUNTADMIN "ALTER TASK $DB.AUDIT.ARCHIVE_DESK_TASK RESUME" && ok "archive task resumed"
    sf_q ACCOUNTADMIN "ALTER COMPUTE POOL $POOL RESUME" || true
    for s in $AGENT_SVCS; do sf_q "$AGENT_ROLE" "ALTER SERVICE $DB.APP.$s RESUME" && ok "$s resuming"; done
    sf_q "$SERVICE_ROLE" "ALTER SERVICE $DB.APP.DESK_EXECUTOR RESUME" && ok "DESK_EXECUTOR resuming"
    for p in $(ui_svcs); do sf_q "${p%%:*}" "ALTER SERVICE $DB.APP.${p#*:} RESUME" && ok "${p#*:} resuming"; done
    info "services take 1-3 minutes to become READY; check with ./demo.sh status"
    ;;
  *) sed -n '2,11p' "$0"; exit 2;;
esac
