#!/bin/bash

set -uo pipefail

SECONDS=0

# ---------------------------------------------------------------------
# Determine current quarter (from calendar.env)
# ---------------------------------------------------------------------
eval "$(/opt/ansible/files/common/scripts/determine_quarters.sh)"

# Build provenance directory path
PROV_DIR="/opt/ansible/files/grafana/${quarter}/provenance"
mkdir -p "$PROV_DIR"

# ---------------------------------------------------------------------
# Build log setup
# ---------------------------------------------------------------------
start_time=$(date +%F-%T)
logfile="/opt/ansible/logs/build_grafana_release-${start_time}.log"

echo "=== Build started at ${start_time} ===" | tee -a "$logfile"

# ---------------------------------------------------------------------
# Run the main build playbook
# ---------------------------------------------------------------------
ansible-playbook \
  -vvv \
  --flush-cache \
  -i /opt/ansible/vars/inventory.ini \
  build_grafana_stack.yml \
  --vault-password-file ~/vault_pass.txt \
  2>&1 | tee -a "$logfile"

# Capture the *playbook's* exit status, not tee's - without this, the
# script always reports success regardless of whether the build failed.
build_status=${PIPESTATUS[0]}

# ---------------------------------------------------------------------
# Build completion + duration
# ---------------------------------------------------------------------
duration=$SECONDS
end_time=$(date +%F-%T)

echo "=== Build finished at ${end_time} ===" | tee -a "$logfile"
echo "=== Total time: $((duration / 60)) minutes $((duration % 60)) seconds ===" | tee -a "$logfile"

if [[ "${build_status}" -ne 0 ]]; then
    echo "=== Build FAILED (ansible-playbook exit ${build_status}) ===" | tee -a "$logfile"
fi

# ---------------------------------------------------------------------
# Publish build status + metrics to Prometheus (best-effort)
# ---------------------------------------------------------------------
# Neither call can change the build result or the signed log: output goes
# to the console only, and failures are downgraded to a warning.
if [[ "${build_status}" -eq 0 ]]; then result=success; else result=fail; fi
/usr/local/bin/emit_event.sh stack grafana "${result}" "${quarter}" 0 || true
/opt/ansible/files/common/scripts/emit_build_metrics.sh "$logfile" grafana \
  || echo "WARNING: build metrics could not be published"

# ---------------------------------------------------------------------
# Sign completed build log as root
# ---------------------------------------------------------------------
sudo -E gpg --batch --yes --pinentry-mode loopback --detach-sign \
    --output "${logfile}.asc" \
    "${logfile}"

# ---------------------------------------------------------------------
# Change log permissions to ansible so it can copy
# ---------------------------------------------------------------------
sudo chown ansible:ansible "$logfile"
sudo chmod 644 "$logfile"
sudo chown ansible:ansible "${logfile}.asc"
sudo chmod 644 "${logfile}.asc"

# ---------------------------------------------------------------------
# Copy completed build log + signature into provenance
# ---------------------------------------------------------------------
cp "$logfile"        "${PROV_DIR}/build.log"
cp "${logfile}.asc"  "${PROV_DIR}/build.log.asc"

echo "=== Build log and signature copied to ${PROV_DIR}/build.log(.asc) ==="

# Propagate the real build result as this script's own exit code, so
# callers (cron, new-quarter.sh) can actually detect a failed build.
exit "${build_status}"
