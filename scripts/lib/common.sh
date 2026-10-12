#!/usr/bin/env bash
# Shared helpers for install.sh, doctor.sh, demo.sh and uninstall.sh.
# Compatible with macOS bash 3.2: no associative arrays, no ${var,,}, no mapfile.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
CONFIG="${DESK_CONFIG:-$ROOT/config/demo.env}"
VARS="$BUILD/vars.env"
STATE="$BUILD/state"
LOGS="$BUILD/logs"
ASSUME_YES="${ASSUME_YES:-0}"
export COLUMNS=100000   # snow wraps output at terminal width otherwise

# ---------------------------------------------------------------- output
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else B=; G=; Y=; R=; C=; N=; fi
step()  { printf '\n%s== %s%s\n' "$B$C" "$*" "$N"; }
info()  { printf '   %s\n' "$*"; }
ok()    { printf '   %s[ok]%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '   %s[warn]%s %s\n' "$Y" "$N" "$*"; }
fail()  { printf '   %s[fail]%s %s\n' "$R" "$N" "$*"; }
# die <message> [hint...]: stop the install with an explanation and what to do next.
die() {
  local msg="$1"; shift
  printf '\n%s[stopped]%s %s\n' "$R$B" "$N" "$msg"
  for h in "$@"; do printf '   -> %s\n' "$h"; done
  printf '   Logs: %s\n   Resume with: ./install.sh --from %s\n' "$LOGS" "${CURRENT_STAGE:-<stage>}"
  exit 1
}

# ask "question" -> 0 for yes. Honors --yes.
ask() {
  [ "$ASSUME_YES" = 1 ] && { info "$1 [auto-yes]"; return 0; }
  local a; printf '   %s?%s %s [y/N] ' "$Y" "$N" "$1"; read -r a </dev/tty || a=n
  case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
# choose "question" default opt1 opt2 ... -> echoes the choice
choose() {
  local q="$1" def="$2"; shift 2
  if [ "$ASSUME_YES" = 1 ]; then echo "$def"; return; fi
  local a; printf '   %s?%s %s (%s) [%s] ' "$Y" "$N" "$q" "$*" "$def" >&2; read -r a </dev/tty || a=
  a="${a:-$def}"
  for o in "$@"; do [ "$o" = "$a" ] && { echo "$a"; return; }; done
  echo "$def"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------- config and derived names
load_config() {
  [ -f "$CONFIG" ] || die "No config at $CONFIG" "cp config/demo.example.env config/demo.env and edit it"
  # shellcheck disable=SC1090
  set -a; . "$CONFIG"; set +a
  case "$PREFIX" in ''|*[!A-Z0-9_]*|[0-9_]*) die "PREFIX must be upper-case letters, digits and _ (got '$PREFIX')";; esac
  case "$UI" in streamlit|node|both) ;; *) die "UI must be streamlit, node or both (got '$UI')";; esac
  case "$PG_MODE" in create|existing) ;; *) die "PG_MODE must be create or existing";; esac
  [ "${#PREFIX}" -le 30 ] || die "PREFIX is too long (max 30 characters)"
  VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
  DB="$PREFIX"; WH="${PREFIX}_WH"; POOL="${PREFIX}_POOL"; EAI="${PREFIX}_PG_EAI"; PG_POLICY="${PREFIX}_PG_POLICY"
  SERVICE_ROLE="${PREFIX}_SERVICE_ROLE"; AGENT_ROLE="${PREFIX}_AGENT_ROLE"
  COMMAND_ROLE="${PREFIX}_COMMAND_ROLE"; APPROVER_ROLE="${PREFIX}_APPROVER"
  MIRROR_DB="${PREFIX}_MIRROR"; MIRROR_NAME="$(lower "$PREFIX")_mirror"
  PG_INSTANCE="${PG_INSTANCE:-$(lower "$PREFIX")_pg}"
  REPO_PATH="/$(lower "$DB")/app/desk_repo"
  mkdir -p "$BUILD/sql" "$LOGS" "$STATE"
}

# Write every name the templates may use. Call again after values (PG_HOST etc.) are discovered.
write_vars() {
  local today; today=$(date -u +%Y-%m-%d)
  : "${TRADE_DATE:=$today}"
  : "${SETTLE_DATE:=$(python3 -c "import datetime as d;t=d.date.fromisoformat('$TRADE_DATE');n=t+d.timedelta(1)
while n.weekday()>4: n+=d.timedelta(1)
print(n)")}"
  : "${SSI_CHANGE_DATE:=$(python3 -c "import datetime as d;print(d.date.fromisoformat('$TRADE_DATE')-d.timedelta(7))")}"
  cat > "$VARS" <<EOF
PREFIX=$PREFIX
VERSION=$VERSION
DB=$DB
WH=$WH
POOL=$POOL
POOL_INSTANCE_FAMILY=$POOL_INSTANCE_FAMILY
POOL_MAX_NODES=$POOL_MAX_NODES
EAI=$EAI
PG_POLICY=$PG_POLICY
SERVICE_ROLE=$SERVICE_ROLE
AGENT_ROLE=$AGENT_ROLE
COMMAND_ROLE=$COMMAND_ROLE
APPROVER_ROLE=$APPROVER_ROLE
MIRROR_DB=$MIRROR_DB
MIRROR_NAME=$MIRROR_NAME
MIRROR_REFRESH=$MIRROR_REFRESH
PG_INSTANCE=$PG_INSTANCE
PG_HOST=${PG_HOST:-}
REPO_PATH=$REPO_PATH
INSTALL_USER=${INSTALL_USER:-}
INVESTIGATOR_MODEL=$INVESTIGATOR_MODEL
INVESTIGATOR_ALT_MODEL=$INVESTIGATOR_ALT_MODEL
QC_MODEL=$QC_MODEL
FLIGHT_RECORDER_MODEL=$FLIGHT_RECORDER_MODEL
TRADE_DATE=$TRADE_DATE
SETTLE_DATE=$SETTLE_DATE
SSI_CHANGE_DATE=$SSI_CHANGE_DATE
EGRESS_CIDRS=${EGRESS_CIDRS:-}
EGRESS_EXPIRES=${EGRESS_EXPIRES:-}
EOF
}

# Persist discovered values (PG_HOST, INSTALL_USER, dates) across resumed runs.
remember() { printf '%s=%s\n' "$1" "$2" >> "$STATE/discovered.env"; eval "$1=\"\$2\""; }
recall() { [ -f "$STATE/discovered.env" ] && { set -a; . "$STATE/discovered.env"; set +a; }; return 0; }

render() {  # render <src relative to ROOT> -> prints path of rendered file
  local src="$1" dst="$BUILD/sql/$(basename "$1")"
  python3 "$ROOT/scripts/lib/render.py" "$VARS" "$ROOT/$src" "$dst" || die "Template render failed for $src"
  echo "$dst"
}

# ---------------------------------------------------------------- Snowflake
SNOW() { snow sql -c "$SNOW_CONNECTION" "$@"; }

# Non-ACCOUNTADMIN calls disable secondary roles so a check sees exactly what the service sees
# (a user with DEFAULT_SECONDARY_ROLES = ALL would otherwise inherit ACCOUNTADMIN's privileges).
as_role() { [ "$1" = ACCOUNTADMIN ] && printf '%s' "$2" || printf 'USE SECONDARY ROLES NONE;\nUSE WAREHOUSE %s;\n%s' "$WH" "$2"; }

# sf_q <role> <sql>: run, log, return snow's exit code.
sf_q() {
  local role="$1" sql; sql=$(as_role "$1" "$2"); local log="$LOGS/sql.log"
  { echo "--- $(date '+%H:%M:%S') [$role]"; echo "$sql"; } >> "$log"
  SNOW --role "$role" -q "$sql" >> "$log" 2>&1
}
# sf_file <role> <rendered file>
sf_file() {
  local role="$1" f="$2" log="$LOGS/$(basename "$2").log"
  if [ "$role" != ACCOUNTADMIN ]; then as_role "$role" "$(cat "$f")" > "$f.as_role"; f="$f.as_role"; fi
  SNOW --role "$role" -f "$f" > "$log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] || grep -qE "^[0-9]{6} \([0-9A-Z]{5}\)" "$log"; then
    grep -E "^[0-9]{6} \(|rror" "$log" | head -5 | sed 's/^/      /'
    return 1
  fi
  return 0
}
# sf_json <role> <sql>: JSON rows on stdout ('[]' on failure).
sf_json() {
  local out
  out=$(SNOW --role "$1" --format json -q "$(as_role "$1" "$2")" 2>>"$LOGS/sql.log") || { echo '[]'; return 1; }
  python3 -c 'import sys,json
t=sys.stdin.read(); i=t.find("[")
rows=json.loads(t[i:]) if i>=0 else []
if rows and isinstance(rows[0], list): rows=rows[-1]
print(json.dumps(rows))' <<<"$out" 2>/dev/null || echo '[]'
}
# sf_val <role> <sql>: first column of first row, or empty.
sf_val() {
  sf_json "$1" "$2" | python3 -c 'import sys,json
r=json.load(sys.stdin)
print("" if not r else (list(r[0].values())[0] if list(r[0].values())[0] is not None else ""))'
}
# jq-free JSON field extraction: json_get <json> <python expr on r>
json_get() { python3 -c "import sys,json;r=json.loads(sys.argv[1]);print($2)" "$1"; }

# Add ALTER SERVICE ... FROM SPECIFICATION after each CREATE SERVICE IF NOT EXISTS so re-runs
# upgrade a service in place (public endpoint URLs survive) instead of no-op'ing.
upsert_services() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
out = []
for m in re.finditer(r"CREATE SERVICE IF NOT EXISTS (\S+)(.*?)FROM SPECIFICATION \$\$(.*?)\$\$;", s, re.S):
    out.append(f"ALTER SERVICE {m.group(1)} FROM SPECIFICATION $${m.group(3)}$$;")
open(p, "w").write(s + "\n-- upsert\n" + "\n".join(out) + "\n")
PY
}

service_status() {  # service_status <role> <service> -> READY / PENDING / FAILED / ... (first container)
  sf_val "$1" "SELECT PARSE_JSON(SYSTEM\$GET_SERVICE_STATUS('$DB.APP.$2'))[0]:status::STRING"
}
service_logs() {    # service_logs <role> <service> <container> [lines]
  sf_val "$1" "SELECT SYSTEM\$GET_SERVICE_LOGS('$DB.APP.$2', 0, '$3', ${4:-200})"
}
# wait_ready <role> <service> <timeout_s>
wait_ready() {
  local t=0 s
  while [ "$t" -lt "$3" ]; do
    s=$(service_status "$1" "$2")
    case "$s" in READY) ok "$2 READY"; return 0;; FAILED) fail "$2 FAILED"; return 1;; esac
    sleep 10; t=$((t + 10))
  done
  fail "$2 not READY after $3s (status: ${s:-unknown})"; return 1
}

# ---------------------------------------------------------------- Postgres via SPCS job
# pg_job <tag> <file@login> [file@login ...]
# Uploads the (rendered) SQL files to the stage and runs agents/app/sqlrun.py in a job service as
# SERVICE_ROLE with every desk login mounted. Output lands in $LOGS/pg_<tag>.log.
pg_job() {
  local tag="$1"; shift
  local files="" item f login name="PGJOB_$(date +%s)" log="$LOGS/pg_$tag.log"
  for item in "$@"; do
    f="${item%@*}"; login="${item##*@}"
    SNOW --role ACCOUNTADMIN -q "PUT 'file://$f' @$DB.APP.DESK_SQL AUTO_COMPRESS=FALSE OVERWRITE=TRUE" \
      >> "$LOGS/sql.log" 2>&1 || { fail "upload $f"; return 1; }
    files="$files /sql/$(basename "$f")@$login"
  done
  cat > "$BUILD/sql/pgjob_$tag.sql" <<EOF
EXECUTE JOB SERVICE IN COMPUTE POOL $POOL NAME = $DB.APP.$name
  EXTERNAL_ACCESS_INTEGRATIONS = ($EAI)
  FROM SPECIFICATION \$\$
spec:
  containers:
  - name: run
    image: $REPO_PATH/desk-agents:$VERSION
    args: ["sqlrun.py"]
    env:
      PGHOST: $PG_HOST
      SQL_FILES: "${files# }"
    secrets:
    - {snowflakeSecret: $DB.APP.PG_ADMIN_SECRET, directoryPath: /secrets/pg_admin}
    - {snowflakeSecret: $DB.APP.PG_DESK_SECRET, directoryPath: /secrets/desk_app}
    - {snowflakeSecret: $DB.APP.PG_QC_SECRET, directoryPath: /secrets/desk_qc}
    - {snowflakeSecret: $DB.APP.PG_EXEC_SECRET, directoryPath: /secrets/desk_exec}
    - {snowflakeSecret: $DB.APP.PG_APPROVER_SECRET, directoryPath: /secrets/desk_approver_svc}
    - {snowflakeSecret: $DB.APP.PG_SIM_SECRET, directoryPath: /secrets/desk_sim}
    - {snowflakeSecret: $DB.APP.PG_CA_SECRET, directoryPath: /secrets/pg_ca}
    volumeMounts:
    - {name: sql, mountPath: /sql}
  volumes:
  - {name: sql, source: '@$DB.APP.DESK_SQL'}
\$\$;
EOF
  SNOW --role "$SERVICE_ROLE" -f "$BUILD/sql/pgjob_$tag.sql" > "$log.job" 2>&1
  service_logs "$SERVICE_ROLE" "$name" run 1000 > "$log"
  SNOW --role "$SERVICE_ROLE" -q "DROP SERVICE IF EXISTS $DB.APP.$name" >/dev/null 2>&1
  if grep -q "SQLRUN_DONE" "$log"; then return 0; fi
  grep -hE "SQLRUN_ERROR|rror" "$log" "$log.job" | head -5 | sed 's/^/      /'
  return 1
}

# ---------------------------------------------------------------- stage bookkeeping
stage_done()  { [ -f "$STATE/$1.done" ]; }
mark_done()   { date '+%Y-%m-%dT%H:%M:%S' > "$STATE/$1.done"; }
