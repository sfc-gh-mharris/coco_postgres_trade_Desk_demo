#!/usr/bin/env bash
# Repository hygiene: fail if account-specific values, local paths, or key material are committed.
# Runs in CI and before every push. Add new patterns here when a value must never ship.
set -uo pipefail
cd "$(dirname "$0")/../.."

patterns='mharris|MHARRIS|demo-awse|DEMO_AWSE|sfsenorthamerica|SFSENORTHAMERICA|/Users/|3v3tvjod|agent_test|CORTEX_POSTGRES_TESTING|bra4qhkn|fra4qhkn|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
hits=$(git ls-files -co --exclude-standard 2>/dev/null | grep -vE '^(scripts/ci/scan\.sh|command/package-lock\.json)$' \
  | xargs grep -nIE "$patterns" 2>/dev/null | grep -v 'github.com/sfc-gh-mharris/coco_postgres_trade_Desk_demo')
pems=$(git ls-files -co --exclude-standard 2>/dev/null | grep -E '\.(pem|p8|key)$')
rc=0
[ -n "$hits" ] && { echo "Account-specific or sensitive values found:"; echo "$hits"; rc=1; }
[ -n "$pems" ] && { echo "Key/certificate files found:"; echo "$pems"; rc=1; }
# Templates must only use variables the installer defines.
known=$(grep -oE '^[A-Z_]+=' scripts/lib/common.sh | tr -d '=' | sort -u)
used=$(grep -rhoE '\{\{[A-Z][A-Z0-9_]*\}\}' sql | tr -d '{}' | sort -u)
for v in $used; do echo "$known" | grep -qx "$v" || { echo "template variable {{$v}} is not defined in write_vars"; rc=1; }; done
[ $rc = 0 ] && echo "scan: clean"
exit $rc
