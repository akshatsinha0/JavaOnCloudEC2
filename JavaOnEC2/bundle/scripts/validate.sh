#!/bin/bash
set -euo pipefail
for i in $(seq 1 90); do
  if wget -qO- http://localhost/health >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
# on failure, print last 60 lines to CodeDeploy logs for diagnosis, then fail
journalctl -u app -n 60 --no-pager || true
echo "health check timeout" >&2
exit 1