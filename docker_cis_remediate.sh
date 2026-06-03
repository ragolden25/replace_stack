docker_cis_remediate.sh
#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

backup_file() {
    local f="$1"
    if [[ -f "$f" && ! -f "${f}.bak" ]]; then
        cp -p "$f" "${f}.bak"
        log "Backup created: ${f}.bak"
    fi
}

COMPOSE_FILE="/var/lib/containers/compose/docker-compose.yml"
DAEMON_JSON="/etc/docker/daemon.json"

# ---------------------------------------------------------
# Ensure jq is installed
# ---------------------------------------------------------
log "Checking jq installation"

if ! command -v jq >/dev/null 2>&1; then
    log "jq not found — installing..."
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    else
        log "ERROR: No supported package manager found"
        exit 1
    fi
else
    log "jq already installed"
fi

# ---------------------------------------------------------
# Ensure icc=false in daemon.json
# ---------------------------------------------------------
log "Ensuring icc=false in $DAEMON_JSON"
mkdir -p "$(dirname "$DAEMON_JSON")"

if [[ ! -f "$DAEMON_JSON" ]]; then
    cat > "$DAEMON_JSON" <<EOF
{
  "icc": false
}
EOF
    log "Created $DAEMON_JSON with icc=false"
else
    backup_file "$DAEMON_JSON"
    tmp=$(mktemp)

    if jq -e '.icc' "$DAEMON_JSON" >/dev/null 2>&1; then
        jq '.icc = false' "$DAEMON_JSON" > "$tmp"
    else
        jq '. + {"icc": false}' "$DAEMON_JSON" > "$tmp"
    fi

    mv "$tmp" "$DAEMON_JSON"
    log "Updated icc=false in existing $DAEMON_JSON"
fi

log "Restarting Docker to apply daemon.json"
systemctl restart docker

# ---------------------------------------------------------
# Determine host IP on OOB network
# ---------------------------------------------------------
HOST_IP=$(ip -4 addr show | awk '/inet 192\.168\.110\./ {print $2}' | cut -d/ -f1 | head -n1)

if [[ -z "${HOST_IP:-}" ]]; then
    log "ERROR: Unable to determine host IP on 192.168.110.0/24"
    exit 1
fi

log "Detected OOB host IP: $HOST_IP"

# ---------------------------------------------------------
# Validate unified compose file
# ---------------------------------------------------------
if [[ ! -f "$COMPOSE_FILE" ]]; then
    log "ERROR: Unified compose file not found: $COMPOSE_FILE"
    exit 1
fi

backup_file "$COMPOSE_FILE"

# ---------------------------------------------------------
# Patch ports in unified compose (CIS-compliant)
# ---------------------------------------------------------
log "Patching ports in unified compose file: $COMPOSE_FILE"

# nginx → bind to host IP
sed -i \
    -e "s/[\"']80:80[\"']/\"${HOST_IP}:80:80\"/" \
    -e "s/[\"']443:443[\"']/\"${HOST_IP}:443:443\"/" \
    "$COMPOSE_FILE"

# grafana → bind to 127.0.0.1
sed -i \
    -e "s/[\"']3000:3000[\"']/\"127.0.0.1:3000:3000\"/" \
    "$COMPOSE_FILE"

# prometheus → bind to 127.0.0.1
sed -i \
    -e "s/[\"']9191:9090[\"']/\"127.0.0.1:9191:9090\"/" \
    "$COMPOSE_FILE"

# idrac_exporter → bind to host IP (required for nginx)
sed -i \
    -e "s/[\"']9348:9348[\"']/\"${HOST_IP}:9348:9348\"/" \
    "$COMPOSE_FILE"

# ---------------------------------------------------------
# Validate idrac_exporter container
# ---------------------------------------------------------
log "Validating idrac_exporter container"

if ! docker ps --format '{{.Names}}' | grep -q '^idrac_exporter$'; then
    log "WARNING: idrac_exporter container not running"
else
    log "idrac_exporter container detected"

    # Check internal port 9348
    if docker exec idrac_exporter bash -c "netstat -tln | grep -q ':9348 '" 2>/dev/null; then
        log "idrac_exporter is listening on port 9348 internally"
    else
        log "ERROR: idrac_exporter is NOT listening on port 9348"
    fi

    # Check network attachment
    if docker inspect idrac_exporter | grep -q '"grafana_net"'; then
        log "idrac_exporter is correctly attached to grafana_net"
    else
        log "ERROR: idrac_exporter is NOT attached to grafana_net"
    fi

    # Validate published ports are CIS-compliant (no wildcard binds)
    PORT_BINDINGS=$(docker inspect idrac_exporter | jq -r '.[0].NetworkSettings.Ports | to_entries[] | .value[]?.HostIp')

    for ip in $PORT_BINDINGS; do
        if [[ "$ip" == "0.0.0.0" || "$ip" == "::" ]]; then
            log "idrac_exporter is bound to wildcard IP ($ip), remediating via patched compose (${HOST_IP}:9348:9348)"
            # Compose file is already patched above; stack restart below will apply it.
        else
            log "idrac_exporter port binding is CIS-compliant: $ip"
        fi
    done
fi

# ---------------------------------------------------------
# Restart entire stack
# ---------------------------------------------------------
log "Restarting entire Grafana stack using unified compose"
docker compose -f "$COMPOSE_FILE" up -d

log "Docker CIS remediation complete."
exit 0
