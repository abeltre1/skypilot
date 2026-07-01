#!/usr/bin/env bash
# Verify the multi-cluster HPC + OCP prototype wiring.
#
# Usage:
#   ./verify.sh                # static checks only (no cluster access)
#   ./verify.sh --live         # also launch a probe on each target
#
# Static checks (safe, no jobs submitted):
#   1. ~/.sky/config.yaml loads and passes schema validation
#   2. `sky check` enumerates enabled infra (Slurm clusters, K8s/OCP contexts)
#   3. `sky check ssh` enumerates SSH Node Pools (if any)
#   4. `sky status` prints the "Enabled Infra:" line
#
# Live checks (--live): launch task-hpc / task-ocp / task-any, tail logs, tear
# down. Requires clusters reachable (and MFA masters pre-authenticated).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; RC=1; }
RC=0

echo "== Static checks =="

# 1. Config schema validation. skypilot_config validates against the schema on
#    load; a schema error raises here.
if python - <<'PY'
import os, sys
from sky import skypilot_config
path = skypilot_config.get_user_config_path()
if not os.path.exists(path):
    print("      no config at", path, "-- create ~/.sky/config.yaml first")
    sys.exit(1)
try:
    skypilot_config.parse_and_validate_config_file(path)
    print("      validated:", path)
except Exception as e:  # noqa: BLE001
    print("      ", e)
    sys.exit(1)
PY
then pass "~/.sky/config.yaml loads and validates"
else fail "~/.sky/config.yaml failed to load / validate"
fi

# 2. sky check -- which clouds/clusters are enabled.
if sky check 2>&1 | tee /tmp/sky_check.out | grep -Eiq 'slurm|kubernetes'; then
  pass "sky check ran (see output above)"
else
  fail "sky check did not report slurm/kubernetes -- inspect /tmp/sky_check.out"
fi

# 3. SSH Node Pools (optional; only if ssh_node_pools.yaml is deployed).
sky check ssh 2>&1 | sed 's/^/      /' || true

# 4. Enabled infra summary.
if sky status 2>&1 | grep -qi 'Enabled Infra'; then
  pass "sky status shows Enabled Infra"
else
  fail "sky status did not show Enabled Infra"
fi

if [[ $LIVE -eq 0 ]]; then
  echo
  echo "Static checks done (RC=$RC). Re-run with --live to launch probes."
  exit $RC
fi

echo
echo "== Live checks =="
for t in task-hpc task-ocp task-any; do
  c="probe-${t}"
  echo "-- launching ${t} as ${c} --"
  if sky launch -y -c "$c" "${HERE}/tasks/${t}.yaml"; then
    sky logs "$c" || true
    pass "${t} launched"
  else
    fail "${t} failed to launch"
  fi
  sky down -y "$c" 2>/dev/null || true
done

echo
echo "Live checks done (RC=$RC)."
exit $RC
