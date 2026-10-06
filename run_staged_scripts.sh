#!/usr/bin/env bash
# =====================================================================
# Weekly staging-script runner
#
# Runs every stage_*.sh script under /opt/ansible/staged/*/scripts/,
# one after another. A failure in any one script is logged and does
# NOT stop the rest from running (no `set -e` at the top level, and
# each script is invoked in its own subshell so a bad `exit`/`set -e`
# inside a stage script can't kill this runner either).
#
# Exit status: 0 only if every stage script succeeded. Non-zero (the
# count of failed scripts) otherwise, so cron/mail-on-failure and
# monitoring still see that something needs attention, even though
# every script got a chance to run.
# =====================================================================

STAGED_ROOT="/opt/ansible/staged"
LOG_DIR="/opt/ansible/staged/logs"
RUN_DATE="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/run-${RUN_DATE}.log"
LOCK_FILE="/tmp/run_staged_scripts.lock"
EMIT="${EMIT:-/usr/local/bin/emit_event.sh}"
STAGE_INTERVAL=604800   # weekly; lets the dashboard flag a staging job that stopped running

mkdir -p "${LOG_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

# Report each staged project's result to Prometheus (node_exporter textfile
# collector). Best-effort: a missing/broken emit_event.sh never affects staging.
emit_status() { "${EMIT}" "$@" >>"${LOG_FILE}" 2>&1 || true; }

# Prevent overlapping runs (e.g. a prior run still hung) without
# letting a stale lock block things forever.
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  log "ERROR: another run_staged_scripts.sh is already running (lock held on ${LOCK_FILE}). Exiting."
  exit 1
fi

log "==> Starting weekly staged-script run"

declare -a FAILED=()
declare -a SUCCEEDED=()

# One script per staged subdirectory, matched by convention
# (/opt/ansible/staged/<name>/scripts/stage_<name>_source.sh).
# Using a glob here (rather than a hardcoded list) means a newly
# added staged/<name>/ directory is picked up automatically.
shopt -s nullglob
SCRIPTS=("${STAGED_ROOT}"/*/scripts/stage_*.sh)
shopt -u nullglob

if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
  log "ERROR: no stage_*.sh scripts found under ${STAGED_ROOT}/*/scripts/"
  exit 1
fi

for script in "${SCRIPTS[@]}"; do
  name="$(basename "$(dirname "$(dirname "${script}")")")"   # e.g. grafana, idrac, postgres, prometheus

  if [[ ! -x "${script}" ]]; then
    log "SKIP:    ${name} (${script} is missing or not executable)"
    emit_status stage "${name}" fail "" "${STAGE_INTERVAL}"
    FAILED+=("${name}")
    continue
  fi

  log "START:   ${name} (${script})"

  # Run in its own subshell with its own timeout, so:
  #  - a `set -e`/`exit` inside the script only ends that subshell
  #  - a hung script can't block every later one indefinitely
  #  - its stdout/stderr land in the shared log, tagged by name
  if timeout 1800 bash "${script}" >>"${LOG_FILE}" 2>&1; then
    log "SUCCESS: ${name}"
    emit_status stage "${name}" success "" "${STAGE_INTERVAL}"
    SUCCEEDED+=("${name}")
  else
    status=$?
    log "FAILED:  ${name} (exit ${status}) -- continuing with remaining scripts"
    emit_status stage "${name}" fail "" "${STAGE_INTERVAL}"
    FAILED+=("${name}")
  fi
done

log "==> Run complete. Succeeded: ${SUCCEEDED[*]:-none}  Failed: ${FAILED[*]:-none}"

# Prune logs older than 90 days so LOG_DIR doesn't grow unbounded.
find "${LOG_DIR}" -name 'run-*.log' -mtime +90 -delete 2>/dev/null || true

exit "${#FAILED[@]}"
