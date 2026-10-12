#!/usr/bin/env bash
# Verification checks shared by install.sh (after each stage) and doctor.sh (on demand).
# Each check prints ok/fail lines and returns non-zero if anything is missing.

# exists <role> <SHOW ... LIKE ...> <label>
exists() {
  local n; n=$(sf_json "$1" "$2" | json_get "$(cat)" "len(r)" 2>/dev/null)
  if [ "${n:-0}" -ge 1 ]; then ok "$3"; return 0; fi
  fail "$3 missing"; return 1
}

check_foundation() {
  local rc=0
  exists ACCOUNTADMIN "SHOW DATABASES LIKE '$DB'" "database $DB" || rc=1
  for s in REF APP AUDIT; do exists ACCOUNTADMIN "SHOW SCHEMAS LIKE '$s' IN DATABASE $DB" "schema $DB.$s" || rc=1; done
  exists ACCOUNTADMIN "SHOW WAREHOUSES LIKE '$WH'" "warehouse $WH" || rc=1
  exists ACCOUNTADMIN "SHOW COMPUTE POOLS LIKE '$POOL'" "compute pool $POOL" || rc=1
  exists ACCOUNTADMIN "SHOW IMAGE REPOSITORIES LIKE 'DESK_REPO' IN SCHEMA $DB.APP" "image repository" || rc=1
  exists ACCOUNTADMIN "SHOW STAGES LIKE 'DESK_SQL' IN SCHEMA $DB.APP" "SQL stage" || rc=1
  for r in "$SERVICE_ROLE" "$AGENT_ROLE" "$COMMAND_ROLE" "$APPROVER_ROLE"; do
    exists ACCOUNTADMIN "SHOW ROLES LIKE '$r'" "role $r" || rc=1
  done
  return $rc
}

check_postgres() {
  local rc=0 st
  st=$(sf_json ACCOUNTADMIN "SHOW POSTGRES INSTANCES LIKE '$PG_INSTANCE'" | json_get "$(cat)" "r[0]['state'] if r else ''")
  [ "$st" = READY ] && ok "Postgres $PG_INSTANCE READY" || { fail "Postgres $PG_INSTANCE state '${st:-missing}'"; rc=1; }
  for s in PG_ADMIN_SECRET PG_CA_SECRET PG_DESK_SECRET PG_QC_SECRET PG_EXEC_SECRET PG_APPROVER_SECRET PG_SIM_SECRET; do
    exists ACCOUNTADMIN "SHOW SECRETS LIKE '$s' IN SCHEMA $DB.APP" "secret $s" || rc=1
  done
  exists ACCOUNTADMIN "SHOW INTEGRATIONS LIKE '$EAI'" "external access integration $EAI" || rc=1
  exists ACCOUNTADMIN "SHOW NETWORK POLICIES LIKE '$PG_POLICY'" "network policy $PG_POLICY" || rc=1
  # Every role must be able to read the secrets its services mount.
  sf_q "$AGENT_ROLE" "DESCRIBE SECRET $DB.APP.PG_DESK_SECRET" && ok "$AGENT_ROLE can read its secrets" \
    || { fail "$AGENT_ROLE cannot read PG_DESK_SECRET"; rc=1; }
  return $rc
}

check_images() {
  local rc=0 imgs; imgs=$(sf_json ACCOUNTADMIN "SHOW IMAGES IN IMAGE REPOSITORY $DB.APP.DESK_REPO")
  for i in "desk-agents" "desk-command"; do
    if [ "$i" = desk-command ] && [ "$UI" = streamlit ]; then continue; fi
    if json_get "$imgs" "any(x['image_name']=='$i' and x['tags']=='$VERSION' for x in r)" | grep -q True; then
      ok "image $i:$VERSION"
    else fail "image $i:$VERSION not in repository"; rc=1; fi
  done
  return $rc
}

check_refdata() {
  local rows; rows=$(sf_json "$SERVICE_ROLE" "SELECT BATCH, COUNT(*) N FROM $DB.REF.BREAK_SCENARIOS GROUP BY 1")
  if json_get "$rows" "{x['BATCH']:x['N'] for x in r}=={'DEMO':500,'EVAL':10,'QC':10}" | grep -q True; then
    ok "BREAK_SCENARIOS: DEMO 500 / EVAL 10 / QC 10"
  else fail "BREAK_SCENARIOS counts wrong: $rows"; return 1; fi
  local ev; ev=$(sf_val "$AGENT_ROLE" "SELECT ARRAY_SIZE(OBJECT_KEYS($DB.REF.TRADE_EVIDENCE('TR-EVAL-0001')))")
  [ "${ev:-0}" -ge 5 ] && ok "TRADE_EVIDENCE() readable by $AGENT_ROLE" || { fail "TRADE_EVIDENCE() not readable by $AGENT_ROLE"; return 1; }
  # Ground truth must stay hidden from the agents.
  if sf_q "$AGENT_ROLE" "SELECT 1 FROM $DB.REF.BREAK_SCENARIOS LIMIT 1"; then
    fail "$AGENT_ROLE can read BREAK_SCENARIOS (ground truth)"; return 1
  fi
  ok "$AGENT_ROLE cannot read ground truth"
}

check_mirror() {
  local rows; rows=$(sf_json ACCOUNTADMIN "CALL SNOWFLAKE.POSTGRES.LIST_MIRRORED_TABLES('$MIRROR_NAME')")
  local n rep
  n=$(json_get "$rows" "len(r)"); rep=$(json_get "$rows" "sum(1 for x in r if (x.get('STATE') or x.get('state'))=='REPLICATING')")
  if [ "${n:-0}" -ge 9 ] && [ "$rep" = "$n" ]; then ok "mirror $MIRROR_NAME: $rep/$n tables REPLICATING"; return 0; fi
  fail "mirror $MIRROR_NAME: ${rep:-0}/${n:-0} tables REPLICATING"; return 1
}

check_agents() {
  local rc=0
  for s in DESK_WORKER DESK_WORKER_CANARY DESK_QC; do
    [ "$(service_status "$AGENT_ROLE" "$s")" = READY ] && ok "$s READY" || { fail "$s not READY"; rc=1; }
  done
  [ "$(service_status "$SERVICE_ROLE" DESK_EXECUTOR)" = READY ] && ok "DESK_EXECUTOR READY" || { fail "DESK_EXECUTOR not READY"; rc=1; }
  return $rc
}

check_audit() {
  local rc=0
  exists ACCOUNTADMIN "SHOW TASKS LIKE 'ARCHIVE_DESK_TASK' IN SCHEMA $DB.AUDIT" "archive task" || rc=1
  exists ACCOUNTADMIN "SHOW SEMANTIC VIEWS LIKE 'DESK_AUDIT_SV' IN SCHEMA $DB.AUDIT" "semantic view DESK_AUDIT_SV" || rc=1
  exists ACCOUNTADMIN "SHOW AGENTS LIKE 'DESK_FLIGHT_RECORDER' IN SCHEMA $DB.AUDIT" "agent DESK_FLIGHT_RECORDER" || rc=1
  return $rc
}

check_ui() {
  local rc=0
  if [ "$UI" != node ]; then
    [ "$(service_status "$SERVICE_ROLE" DESK_CONSOLE)" = READY ] && ok "DESK_CONSOLE (Streamlit) READY" || { fail "DESK_CONSOLE not READY"; rc=1; }
  fi
  if [ "$UI" != streamlit ]; then
    [ "$(service_status "$COMMAND_ROLE" DESK_COMMAND)" = READY ] && ok "DESK_COMMAND (Node) READY" || { fail "DESK_COMMAND not READY"; rc=1; }
  fi
  return $rc
}

endpoint_url() {  # endpoint_url <role> <service>
  sf_json "$1" "SHOW ENDPOINTS IN SERVICE $DB.APP.$2" | json_get "$(cat)" \
    "next((x['ingress_url'] for x in r if x.get('is_public') in (True,'true')), '')"
}
