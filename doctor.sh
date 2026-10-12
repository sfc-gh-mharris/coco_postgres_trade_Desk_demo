#!/usr/bin/env bash
# Health check: re-runs every installer verification without changing anything.
set -uo pipefail
cd "$(dirname "$0")"
. scripts/lib/common.sh
. scripts/lib/checks.sh
load_config; recall; write_vars

rc=0
step "Foundation";      check_foundation || rc=1
step "Postgres";        check_postgres   || rc=1
step "Images";          check_images     || rc=1
step "Reference data";  check_refdata    || rc=1
step "Mirror";          check_mirror     || rc=1
step "Agent services";  check_agents     || rc=1
step "Audit layer";     check_audit      || rc=1
step "Approval UI";     check_ui         || rc=1
step "Live desk (via mirror \$LIVE)"
q=$(sf_json ACCOUNTADMIN "SELECT STATUS, COUNT(*) N FROM $MIRROR_DB.DESK.\"BREAKS\$LIVE\" GROUP BY 1 ORDER BY 1")
info "breaks by status: $(json_get "$q" "', '.join(f\"{x['STATUS']} {x['N']}\" for x in r) or 'none yet'")"
lag=$(sf_val ACCOUNTADMIN "SELECT DATEDIFF('second', (SELECT MAX(OCCURRED_AT) FROM $MIRROR_DB.DESK.DESK_EVENTS), (SELECT MAX(OCCURRED_AT) FROM $MIRROR_DB.DESK.\"DESK_EVENTS\$LIVE\"))")
info "mirror lag behind \$LIVE: ${lag:-?}s"
echo
[ $rc = 0 ] && printf '%sAll checks passed.%s\n' "$G" "$N" || printf '%sSome checks failed; see above. Fix, then ./install.sh --from <stage>.%s\n' "$R" "$N"
exit $rc
