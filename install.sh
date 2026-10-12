#!/usr/bin/env bash
# Break Desk demo installer. Idempotent and resumable.
#
#   ./install.sh                 run every stage not yet done
#   ./install.sh --from images   re-run from a stage onward
#   ./install.sh --only ui       run one stage
#   ./install.sh --ui node       override UI choice (streamlit | node | both)
#   ./install.sh --yes           accept defaults and confirmations (CI / repeat installs)
#
# Each stage applies, then verifies; on failure it stops with the reason and how to fix it.
set -uo pipefail
cd "$(dirname "$0")"
. scripts/lib/common.sh
. scripts/lib/checks.sh

STAGES="preflight foundation postgres images refdata pgschema mirror agents audit ui summary"
FROM=""; ONLY=""; UI_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --ui) UI_OVERRIDE="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    -h|--help) sed -n '2,10p' "$0"; exit 0;;
    *) echo "unknown option $1"; exit 2;;
  esac
done

if [ ! -f "$CONFIG" ]; then
  cp config/demo.example.env "$CONFIG"
  echo "Created $CONFIG from the example. Review it (connection name, PREFIX, UI), then re-run ./install.sh."
  exit 0
fi
load_config
[ -n "$UI_OVERRIDE" ] && UI="$UI_OVERRIDE"
recall
write_vars

# ================================================================ stages

stage_preflight() {
  step "Preflight: tools"
  command -v snow >/dev/null || die "Snowflake CLI (snow) not found" "Install: https://docs.snowflake.com/developer-guide/snowflake-cli/installation/installation"
  command -v python3 >/dev/null || die "python3 not found"
  command -v docker >/dev/null || die "docker not found" "Install Docker Desktop (or Rancher/Colima) and start it"
  docker info >/dev/null 2>&1 || die "Docker daemon is not running" "Start Docker Desktop and re-run"
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required to build linux/amd64 images"
  ok "snow $(snow --version 2>/dev/null | awk '{print $NF}'), python3, docker + buildx"

  step "Preflight: Snowflake connection '$SNOW_CONNECTION'"
  local who; who=$(sf_json ACCOUNTADMIN "SELECT CURRENT_USER() U, CURRENT_ACCOUNT_NAME() A, CURRENT_REGION() R, CURRENT_ROLE() RL")
  [ "$(json_get "$who" "len(r)")" = 1 ] || die "Cannot run SQL as ACCOUNTADMIN on connection '$SNOW_CONNECTION'" \
    "Check: snow connection test -c $SNOW_CONNECTION" "The connection's user must be granted ACCOUNTADMIN"
  remember INSTALL_USER "$(json_get "$who" "r[0]['U']")"
  local region; region=$(json_get "$who" "r[0]['R']")
  ok "user $INSTALL_USER, account $(json_get "$who" "r[0]['A']"), region $region, ACCOUNTADMIN available"
  case "$region" in *AWS*|*AZURE*) ok "cloud supports Postgres mirroring";;
    *) die "Region $region: Snowflake Postgres mirroring is only on AWS and Azure" "Use an AWS or Azure demo account";; esac

  step "Preflight: features"
  sf_q ACCOUNTADMIN "SHOW POSTGRES INSTANCES" && ok "Snowflake Postgres available" \
    || die "SHOW POSTGRES INSTANCES failed: Snowflake Postgres is not available on this account"
  sf_q ACCOUNTADMIN "SHOW COMPUTE POOLS" && ok "Snowpark Container Services available" \
    || die "SPCS not available (trial accounts cannot create compute pools)"
  local cidrs; cidrs=$(sf_val ACCOUNTADMIN "SELECT SYSTEM\$GET_SNOWFLAKE_EGRESS_IP_RANGES()")
  [ -n "$cidrs" ] && [ "$cidrs" != "[]" ] || die "SYSTEM\$GET_SNOWFLAKE_EGRESS_IP_RANGES() returned nothing" \
    "Postgres needs these ranges to admit SPCS; contact your account team"
  remember EGRESS_CIDRS "$(json_get "$cidrs" "','.join(\"'\"+x['ipv4_prefix']+\"'\" for x in r)")"
  remember EGRESS_EXPIRES "$(json_get "$cidrs" "min(x['expires'][:10] for x in r)")"
  ok "SPCS egress ranges: $EGRESS_CIDRS (expire $EGRESS_EXPIRES)"

  step "Preflight: models"
  local m bad="" seen=""
  for m in "$INVESTIGATOR_MODEL" "$INVESTIGATOR_ALT_MODEL" "$QC_MODEL" "$FLIGHT_RECORDER_MODEL"; do
    case " $seen " in *" $m "*) continue;; esac; seen="$seen $m"
    if sf_q ACCOUNTADMIN "SELECT AI_COMPLETE('$m', 'Reply with OK')"; then ok "model $m callable"
    else warn "model $m not callable"; bad="$bad $m"; fi
  done
  if [ -n "$bad" ]; then
    local cur; cur=$(sf_json ACCOUNTADMIN "SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT" | json_get "$(cat)" "r[0]['value'] if r else ''")
    info "CORTEX_ENABLED_CROSS_REGION is currently '$cur'"
    if [ "$CROSS_REGION_OFFER" != NONE ] && ask "Enable cross-region inference (ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = '$CROSS_REGION_OFFER')"; then
      sf_q ACCOUNTADMIN "ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = '$CROSS_REGION_OFFER'" || die "Could not set CORTEX_ENABLED_CROSS_REGION"
      for m in $bad; do sf_q ACCOUNTADMIN "SELECT AI_COMPLETE('$m', 'Reply with OK')" && ok "model $m callable" \
        || die "Model $m is still not available" "Pick another model in config/demo.env (INVESTIGATOR_MODEL / QC_MODEL / ...)"; done
    else
      die "Models not available:$bad" "Enable cross-region inference, or change the model names in config/demo.env"
    fi
  fi

  step "Preflight: names"
  info "prefix $PREFIX -> database $DB, warehouse $WH, pool $POOL, Postgres $PG_INSTANCE, mirror db $MIRROR_DB"
  if ! stage_done mirror && [ -n "$(sf_val ACCOUNTADMIN "SHOW DATABASES LIKE '$MIRROR_DB'")" ]; then
    die "Database $MIRROR_DB already exists; a mirror needs a new target database" \
      "Choose a different PREFIX in config/demo.env, or run ./uninstall.sh for the old install"
  fi
  if [ "$PG_MODE" = create ] && ! stage_done postgres && [ -n "$(sf_val ACCOUNTADMIN "SHOW POSTGRES INSTANCES LIKE '$PG_INSTANCE'")" ]; then
    die "Postgres instance $PG_INSTANCE already exists" "Set PG_MODE=existing to reuse it, or choose a different PREFIX"
  fi
  if [ "$PG_MODE" = existing ] && [ -z "$(sf_val ACCOUNTADMIN "SHOW POSTGRES INSTANCES LIKE '$PG_INSTANCE'")" ]; then
    die "PG_MODE=existing but instance '$PG_INSTANCE' was not found" "Set PG_INSTANCE in config/demo.env"
  fi
  [ -n "$(sf_val ACCOUNTADMIN "SHOW DATABASES LIKE '$DB'")" ] && ! stage_done foundation && \
    { ask "Database $DB already exists. Install into it anyway" || die "Choose a different PREFIX"; }
  ok "names are free"
  info "UI to deploy: $UI"
}

stage_foundation() {
  step "Foundation: database, warehouse, pool, repository, roles"
  write_vars
  sf_file ACCOUNTADMIN "$(render sql/snowflake/10_foundation.sql)" || die "Foundation SQL failed" "See $LOGS/10_foundation.sql.log"
  local u
  for u in $(echo "$APPROVER_USERS" | tr ',' ' '); do
    sf_q ACCOUNTADMIN "GRANT ROLE $APPROVER_ROLE TO USER \"$u\"" && ok "approver role granted to $u" || warn "could not grant $APPROVER_ROLE to $u"
  done
  check_foundation || die "Foundation objects missing after apply"
}

stage_postgres() {
  step "Postgres instance ($PG_MODE): $PG_INSTANCE"
  if [ "$PG_MODE" = create ] && [ -z "$(sf_val ACCOUNTADMIN "SHOW POSTGRES INSTANCES LIKE '$PG_INSTANCE'")" ]; then
    # The CREATE output includes one-time credentials; they are discarded here and rotated
    # into a secret below, so nothing sensitive is printed or logged.
    SNOW --role ACCOUNTADMIN -q "CREATE POSTGRES INSTANCE \"$PG_INSTANCE\" COMPUTE_FAMILY = '$PG_COMPUTE_FAMILY'
      STORAGE_SIZE_GB = $PG_STORAGE_GB AUTHENTICATION_AUTHORITY = POSTGRES_OR_SNOWFLAKE POSTGRES_VERSION = $PG_VERSION
      COMMENT = 'Break desk demo ($PREFIX)'" >/dev/null 2>&1 || die "CREATE POSTGRES INSTANCE failed" \
      "Run it in Snowsight to see the error; check PG_COMPUTE_FAMILY (BURST_* does not support mirroring)"
    ok "instance requested"
  fi
  info "waiting for READY (new instances take a few minutes)"
  local t=0 st=""
  while [ $t -lt 1200 ]; do
    st=$(sf_json ACCOUNTADMIN "SHOW POSTGRES INSTANCES LIKE '$PG_INSTANCE'" | json_get "$(cat)" "r[0]['state'] if r else ''")
    [ "$st" = READY ] && break; sleep 20; t=$((t + 20)); printf '      %s (%ss)\n' "${st:-?}" "$t"
  done
  [ "$st" = READY ] || die "Postgres instance not READY after 20 minutes (state $st)"
  remember PG_HOST "$(sf_json ACCOUNTADMIN "SHOW POSTGRES INSTANCES LIKE '$PG_INSTANCE'" | json_get "$(cat)" "r[0]['host']")"
  ok "READY at $PG_HOST"
  write_vars

  step "Postgres CA certificate -> secret"
  local cert; cert=$(sf_json ACCOUNTADMIN "DESCRIBE POSTGRES INSTANCE \"$PG_INSTANCE\"" | json_get "$(cat)" \
    "next(x['value'] for x in r if x['property']=='certificate')")
  case "$cert" in *"BEGIN CERTIFICATE"*) ;; *) die "Could not read the instance certificate from DESCRIBE POSTGRES INSTANCE";; esac
  python3 - "$cert" "$BUILD/sql/ca_secret.sql" "$DB" <<'PY'
import sys
cert, out, db = sys.argv[1], sys.argv[2], sys.argv[3]
lit = cert.replace("\\", "\\\\").replace("'", "\\'")
open(out, "w").write(f"CREATE OR REPLACE SECRET {db}.APP.PG_CA_SECRET TYPE = GENERIC_STRING SECRET_STRING = '{lit}'\n"
                     "  COMMENT = 'Postgres root CA (public certificate) for sslmode=verify-full';\n")
PY
  sf_file ACCOUNTADMIN "$BUILD/sql/ca_secret.sql" || die "Could not create PG_CA_SECRET"
  ok "PG_CA_SECRET (public root CA, per account)"

  step "Postgres network: egress rule + EAI, ingress policy (SPCS ranges only)"
  sf_file ACCOUNTADMIN "$(render sql/snowflake/20_pg_network.sql)" || die "Network SQL failed" "See $LOGS/20_pg_network.sql.log"
  ok "egress $PG_HOST:5432, ingress $EGRESS_CIDRS"

  step "Postgres credentials -> secrets"
  if [ "$PG_MODE" = create ]; then
    if [ -z "$(sf_val ACCOUNTADMIN "SHOW SECRETS LIKE 'PG_ADMIN_SECRET' IN SCHEMA $DB.APP")" ]; then
      sf_file ACCOUNTADMIN "$(render sql/snowflake/22_pg_admin_secret.sql)" || die "Could not rotate snowflake_admin into PG_ADMIN_SECRET"
    fi
  else
    [ -n "$(sf_val ACCOUNTADMIN "SHOW SECRETS LIKE 'PG_ADMIN_SECRET' IN SCHEMA $DB.APP")" ] || die \
      "PG_MODE=existing needs $DB.APP.PG_ADMIN_SECRET" \
      "In Snowsight run: CREATE SECRET $DB.APP.PG_ADMIN_SECRET TYPE=PASSWORD USERNAME='snowflake_admin' PASSWORD='<password>';" \
      "Then: ./install.sh --from postgres"
  fi
  ok "PG_ADMIN_SECRET present (value never leaves Snowflake)"
  sf_file ACCOUNTADMIN "$(render sql/snowflake/21_pg_secrets.sql)" || die "Desk login secrets failed" "See $LOGS/21_pg_secrets.sql.log"
  check_postgres || die "Postgres objects missing after apply"
}

stage_images() {
  step "Container images ($VERSION)"
  local reg; reg=$(snow spcs image-registry url -c "$SNOW_CONNECTION" 2>/dev/null | tail -1)
  [ -n "$reg" ] || die "Could not read the image registry URL" "snow spcs image-registry url -c $SNOW_CONNECTION"
  snow spcs image-registry login -c "$SNOW_CONNECTION" > "$LOGS/registry_login.log" 2>&1 \
    || die "docker login to $reg failed" "See $LOGS/registry_login.log"
  ok "logged in to $reg"
  local img
  for img in desk-agents desk-command; do
    if [ "$img" = desk-command ] && [ "$UI" = streamlit ]; then info "skip desk-command (UI=streamlit)"; continue; fi
    local dir=agents; [ "$img" = desk-command ] && dir=command
    info "building $img (linux/amd64; first build takes a few minutes)"
    docker build --platform linux/amd64 -t "$reg$REPO_PATH/$img:$VERSION" "$dir" > "$LOGS/build_$img.log" 2>&1 \
      || die "docker build $img failed" "See $LOGS/build_$img.log"
    docker push "$reg$REPO_PATH/$img:$VERSION" > "$LOGS/push_$img.log" 2>&1 \
      || die "docker push $img failed" "See $LOGS/push_$img.log" "Re-run: snow spcs image-registry login -c $SNOW_CONNECTION"
    ok "pushed $img:$VERSION"
  done
  check_images || die "Images missing from repository after push"
}

stage_refdata() {
  step "Reference data and break scenarios (trade date $TRADE_DATE, settle $SETTLE_DATE)"
  sf_file ACCOUNTADMIN "$(render sql/snowflake/30_ref_data.sql)" || die "Reference data SQL failed" "See $LOGS/30_ref_data.sql.log"
  check_refdata || die "Reference data checks failed"
}

stage_pgschema() {
  step "Postgres desk schema + governance tests (each test runs as the login that would attempt it)"
  # Agents must not be running while tests seed breaks.
  local s; for s in DESK_WORKER DESK_WORKER_CANARY DESK_QC; do sf_q "$AGENT_ROLE" "ALTER SERVICE IF EXISTS $DB.APP.$s SUSPEND"; done
  sf_q "$SERVICE_ROLE" "ALTER SERVICE IF EXISTS $DB.APP.DESK_EXECUTOR SUSPEND"
  local schema cmd t=(); schema=$(render sql/postgres/desk_schema.sql); cmd=$(render sql/postgres/desk_command.sql)
  local f
  for f in 01_sim@desk_sim 02_app@desk_app 03_approver_pre_qc@desk_approver_svc 04_qc@desk_qc \
           05_approver_approve@desk_approver_svc 06_exec@desk_exec 07_admin@pg_admin 08_close_day@desk_approver_svc; do
    t+=("$ROOT/sql/postgres/tests/${f%@*}.sql@${f#*@}")
  done
  pg_job tests "$schema@pg_admin" "$cmd@pg_admin" "${t[@]}" \
    || die "Schema or test job failed" "See $LOGS/pg_tests.log" "If it is a connection error, check the network policy on $PG_INSTANCE"
  local res; res=$(python3 - "$LOGS/pg_tests.log" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1]):
    if line.startswith("SQLRUN_RESULT") and '"result"' in line:
        rows += json.loads(line.split(" ", 2)[2])
fails = [r["name"] for r in rows if not str(r["result"]).startswith("PASS")]
print(f"{len(rows) - len(fails)} {len(rows)} {' '.join(fails)}")
PY
)
  set -- $res
  [ "${2:-0}" -ge 30 ] && [ "$1" = "$2" ] && ok "governance tests: $1/$2 PASS" || die "Governance tests: ${1:-0}/${2:-0} passed; failing: ${*:3}" "See $LOGS/pg_tests.log"
  # Tests leave state behind (test breaks, kill switch flipped); rebuild clean for the demo.
  pg_job clean "$schema@pg_admin" "$cmd@pg_admin" || die "Clean schema rebuild failed" "See $LOGS/pg_clean.log"
  ok "clean desk schema ready"
}

stage_mirror() {
  step "Mirror Postgres desk schema -> $MIRROR_DB (refresh $MIRROR_REFRESH)"
  if [ -z "$(sf_val ACCOUNTADMIN "SHOW DATABASES LIKE '$MIRROR_DB'")" ]; then
    sf_file ACCOUNTADMIN "$(render sql/snowflake/40_mirror.sql)" || die "CREATE_MIRROR failed" "See $LOGS/40_mirror.sql.log"
  else
    sf_q ACCOUNTADMIN "CALL SNOWFLAKE.POSTGRES.ALTER_MIRROR(mirror_name => '$MIRROR_NAME', add_schemas => ['desk'])" || true
  fi
  info "waiting for the initial snapshot"
  local t=0; until check_mirror >/dev/null 2>&1; do
    [ $t -ge 900 ] && { check_mirror; die "Mirror not replicating after 15 minutes" "CALL SNOWFLAKE.POSTGRES.DESCRIBE_MIRROR('$MIRROR_NAME');"; }
    sleep 20; t=$((t + 20))
  done
  check_mirror
  sf_file ACCOUNTADMIN "$(render sql/snowflake/41_mirror_grants.sql)" || die "Mirror grants failed"
  ok "mirror readable by $COMMAND_ROLE"
}

stage_agents() {
  step "Agent services: investigators, canary, QC, executor"
  local f; f=$(render sql/snowflake/50_agents.sql); upsert_services "$f"
  sf_file "$AGENT_ROLE" "$f" || die "Agent services failed" "See $LOGS/50_agents.sql.log"
  f=$(render sql/snowflake/51_executor.sql); upsert_services "$f"
  sf_file "$SERVICE_ROLE" "$f" || die "Executor service failed" "See $LOGS/51_executor.sql.log"
  for s in DESK_WORKER DESK_WORKER_CANARY DESK_QC; do sf_q "$AGENT_ROLE" "ALTER SERVICE $DB.APP.$s RESUME" || true; done
  sf_q "$SERVICE_ROLE" "ALTER SERVICE $DB.APP.DESK_EXECUTOR RESUME" || true
  wait_ready "$AGENT_ROLE" DESK_WORKER 900 || die "DESK_WORKER did not start" "Logs: SELECT SYSTEM\$GET_SERVICE_LOGS('$DB.APP.DESK_WORKER',0,'worker',100);"
  wait_ready "$AGENT_ROLE" DESK_QC 600 || die "DESK_QC did not start"
  wait_ready "$AGENT_ROLE" DESK_WORKER_CANARY 600 || die "DESK_WORKER_CANARY did not start"
  wait_ready "$SERVICE_ROLE" DESK_EXECUTOR 600 || die "DESK_EXECUTOR did not start"

  step "Smoke test: one EVAL break must reach a proposal"
  local id="EVAL-0001-I$(date +%s)" row
  row=$(sf_json "$SERVICE_ROLE" "SELECT OBJECT_CONSTRUCT('break_id', '$id', 'trade_ref', TRADE_REF, 'custodian', CUSTODIAN,
    'counterparty_id', COUNTERPARTY_ID, 'isin', ISIN, 'currency', CURRENCY, 'settle_date', SETTLE_DATE::STRING,
    'custodian_message', CUSTODIAN_MESSAGE, 'qty_diff', QTY_DIFF, 'price_diff_bps', PRICE_DIFF_BPS, 'cash_diff', CASH_DIFF,
    'priority', PRIORITY)::STRING B, OBJECT_CONSTRUCT('expected_action', EXPECTED_ACTION, 'scenario', SCENARIO,
    'is_qc_trap', IS_QC_TRAP)::STRING T FROM $DB.REF.BREAK_SCENARIOS WHERE BREAK_ID = 'EVAL-0001'")
  python3 - "$row" "$BUILD/sql/smoke_insert.sql" <<'PY'
import json, sys
r = json.loads(sys.argv[1])[0]
q = lambda s: "'" + s.replace("'", "''") + "'"
open(sys.argv[2], "w").write(f"SELECT desk.insert_break({q(r['B'])}::jsonb, {q(r['T'])}::jsonb) AS inserted;\n")
PY
  pg_job smoke "$BUILD/sql/smoke_insert.sql@desk_sim" || die "Could not insert the smoke-test break" "See $LOGS/pg_smoke.log"
  local t=0 st=""
  while [ $t -lt 240 ]; do
    st=$(sf_val ACCOUNTADMIN "SELECT ACTION_TYPE || ' ' || STATUS FROM $MIRROR_DB.DESK.\"PROPOSED_ACTIONS\$LIVE\" WHERE BREAK_ID = '$id' LIMIT 1")
    [ -n "$st" ] && break; sleep 15; t=$((t + 15))
  done
  [ -n "$st" ] && ok "agent proposed: $st (break $id)" || die "No proposal for $id within 4 minutes" \
    "Worker logs: SELECT SYSTEM\$GET_SERVICE_LOGS('$DB.APP.DESK_WORKER',0,'worker',100);"
}

stage_audit() {
  step "Audit archive, semantic view, DESK_FLIGHT_RECORDER agent"
  sf_file ACCOUNTADMIN "$(render sql/snowflake/60_audit.sql)" || die "Audit archive SQL failed" "See $LOGS/60_audit.sql.log"
  sf_q ACCOUNTADMIN "CALL $DB.AUDIT.ARCHIVE_DESK()" || warn "first archive run failed (the task retries every 5 minutes)"
  sf_file ACCOUNTADMIN "$(render sql/snowflake/61_semantic_view.sql)" || die "Semantic view failed" "See $LOGS/61_semantic_view.sql.log"
  sf_file ACCOUNTADMIN "$(render sql/snowflake/62_agent.sql)" || die "Cortex Agent failed" "See $LOGS/62_agent.sql.log"
  sf_file ACCOUNTADMIN "$(render sql/snowflake/63_audit_grants.sql)" || die "Audit grants failed"
  check_audit || die "Audit objects missing"
}

stage_ui() {
  step "Approval UI: $UI"
  local f
  if [ "$UI" != node ]; then
    f=$(render sql/snowflake/70_ui_streamlit.sql); upsert_services "$f"
    sf_file "$SERVICE_ROLE" "$f" || die "Streamlit console failed" "See $LOGS/70_ui_streamlit.sql.log"
    wait_ready "$SERVICE_ROLE" DESK_CONSOLE 600 || die "DESK_CONSOLE did not start"
  fi
  if [ "$UI" != streamlit ]; then
    stage_done images && check_images >/dev/null 2>&1 || { CURRENT_STAGE=images; stage_images; }
    f=$(render sql/snowflake/71_ui_node.sql); upsert_services "$f"
    sf_file "$COMMAND_ROLE" "$f" || die "Node command center failed" "See $LOGS/71_ui_node.sql.log"
    wait_ready "$COMMAND_ROLE" DESK_COMMAND 600 || die "DESK_COMMAND did not start"
  fi
  info "waiting for public endpoints"
  local t=0 u1="" u2=""
  while [ $t -lt 600 ]; do
    [ "$UI" != node ] && u1=$(endpoint_url "$SERVICE_ROLE" DESK_CONSOLE)
    [ "$UI" != streamlit ] && u2=$(endpoint_url "$COMMAND_ROLE" DESK_COMMAND)
    case "$u1$u2" in *rovisioning*|"") sleep 20; t=$((t + 20));; *) break;; esac
  done
  [ -n "$u1" ] && remember CONSOLE_URL "https://$u1" && ok "Streamlit console: https://$u1"
  [ -n "$u2" ] && remember COMMAND_URL "https://$u2" && ok "Node command center: https://$u2"
}

stage_summary() {
  local analytics; analytics=$(render sql/analytics/mirror_analytics.sql)
  step "Installed"
  cat <<EOF
   Approvers (role $APPROVER_ROLE): $INSTALL_USER${APPROVER_USERS:+, $APPROVER_USERS}
   Streamlit console:   ${CONSOLE_URL:-not deployed}
   Node command center: ${COMMAND_URL:-not deployed}
   Flight recorder:     Snowflake Intelligence / CoWork -> agent $DB.AUDIT.DESK_FLIGHT_RECORDER
   Mirror analytics:    $analytics (paste into a Snowsight worksheet)

   Demo script:  docs/DEMO_SCRIPT.md
   Day-of-demo:  ./demo.sh status | seed 10 | close-day | pause | resume
   Health check: ./doctor.sh
   Remove all:   ./uninstall.sh

   Running cost while resumed (approx.): compute pool $POOL_INSTANCE_FAMILY x up to $POOL_MAX_NODES nodes,
   Postgres $PG_COMPUTE_FAMILY, plus Cortex tokens per break. Use ./demo.sh pause between demos.
EOF
}

# ================================================================ driver
started=0; [ -z "$FROM" ] && started=1
for st in $STAGES; do
  [ -n "$FROM" ] && [ "$st" = "$FROM" ] && started=1
  [ -n "$ONLY" ] && [ "$st" != "$ONLY" ] && continue
  [ $started = 1 ] || [ -n "$ONLY" ] || continue
  if [ -z "$FROM$ONLY" ] && stage_done "$st" && [ "$st" != preflight ] && [ "$st" != summary ]; then
    info "stage $st already done ($(cat "$STATE/$st.done")); use --from $st to re-run"; continue
  fi
  CURRENT_STAGE=$st
  write_vars
  "stage_$st"
  mark_done "$st"
done
