#!/usr/bin/env bash
# Remove everything the installer created for this PREFIX. Lists objects and asks before dropping.
#   ./uninstall.sh            interactive
#   ./uninstall.sh --yes      no prompt
#   ./uninstall.sh --keep-postgres   keep the Postgres instance (PG_MODE=existing is always kept)
set -uo pipefail
cd "$(dirname "$0")"
. scripts/lib/common.sh
KEEP_PG=0
for a in "$@"; do case "$a" in --yes|-y) ASSUME_YES=1;; --keep-postgres) KEEP_PG=1;; esac; done
load_config; recall; write_vars
[ "$PG_MODE" = existing ] && KEEP_PG=1

step "Objects to remove (prefix $PREFIX)"
info "services in $DB.APP (agents, executor, UIs, jobs) and compute pool $POOL"
info "mirror $MIRROR_NAME and database $MIRROR_DB"
info "database $DB (reference data, audit archive, semantic view, agent, secrets, image repository)"
info "warehouse $WH, integration $EAI, network policy $PG_POLICY"
info "roles $SERVICE_ROLE, $AGENT_ROLE, $COMMAND_ROLE, $APPROVER_ROLE"
[ $KEEP_PG = 1 ] && info "Postgres instance $PG_INSTANCE: KEPT" || info "Postgres instance $PG_INSTANCE (all desk data)"
ask "Drop all of the above. This cannot be undone" || { info "nothing changed"; exit 0; }

drop() { sf_q ACCOUNTADMIN "$1" && ok "$1" || warn "$1 (failed or already gone)"; }
step "Dropping"
for s in $(sf_json ACCOUNTADMIN "SHOW SERVICES IN SCHEMA $DB.APP" | json_get "$(cat)" "' '.join(x['name'] for x in r)" 2>/dev/null); do
  drop "DROP SERVICE IF EXISTS $DB.APP.$s FORCE"
done
drop "ALTER COMPUTE POOL IF EXISTS $POOL STOP ALL"
drop "DROP COMPUTE POOL IF EXISTS $POOL"
drop "CALL SNOWFLAKE.POSTGRES.DROP_MIRROR('$MIRROR_NAME')"
drop "DROP DATABASE IF EXISTS $MIRROR_DB"
if [ $KEEP_PG = 0 ]; then drop "DROP POSTGRES INSTANCE IF EXISTS \"$PG_INSTANCE\""
else drop "ALTER POSTGRES INSTANCE IF EXISTS \"$PG_INSTANCE\" UNSET NETWORK_POLICY"; fi
drop "DROP NETWORK POLICY IF EXISTS $PG_POLICY"
drop "DROP INTEGRATION IF EXISTS $EAI"
drop "DROP DATABASE IF EXISTS $DB"
drop "DROP WAREHOUSE IF EXISTS $WH"
for r in "$SERVICE_ROLE" "$AGENT_ROLE" "$COMMAND_ROLE" "$APPROVER_ROLE"; do drop "DROP ROLE IF EXISTS $r"; done
rm -rf "$STATE"
ok "uninstalled; config/demo.env kept"
