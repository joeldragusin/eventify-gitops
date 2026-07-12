#!/usr/bin/env bash
# Fire concurrent requests at /api/events to drive CPU up and trigger the HPA.
set -euo pipefail

NAMESPACE="eventify"
TARGET="http://eventify-backend.${NAMESPACE}.svc.cluster.local/api/events"
WORKERS="${1:-50}"          # concurrent loops (default 50); pass a number to override

echo "Launching a load-generator pod hitting ${TARGET} with ${WORKERS} parallel loops..."
echo "Press Ctrl+C to stop, then run: kubectl delete pod load-gen -n ${NAMESPACE}"

kubectl run load-gen -n "${NAMESPACE}" --image=busybox --restart=Never -- \
  /bin/sh -c "for i in \$(seq 1 ${WORKERS}); do while true; do wget -q -O- ${TARGET} >/dev/null 2>&1; done & done; wait"
