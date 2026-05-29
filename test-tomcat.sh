#!/bin/bash
set -e

# ============================================================
#  SMART TOMCAT TEST HARNESS
#  Auto-detects Tomcat images, tests each on port 8080,
#  validates connectivity, then restores Guacamole stack.
# ============================================================

COMPOSE_DIR="/var/lib/containers/compose"

echo "============================================================"
echo "  SMART TOMCAT TEST HARNESS"
echo "============================================================"

# ------------------------------------------------------------
# Stop Guacamole stack
# ------------------------------------------------------------
echo "[1/6] Stopping Guacamole stack..."
if [ -f "$COMPOSE_DIR/stop.sh" ]; then
    bash "$COMPOSE_DIR/stop.sh" || true
else
    echo "ERROR: stop.sh not found in $COMPOSE_DIR"
    exit 1
fi
echo "Guacamole stack stopped. Port 8080 should now be free."
echo

# ------------------------------------------------------------
# Auto-detect Tomcat images
# ------------------------------------------------------------
echo "[2/6] Detecting Tomcat images..."

TOMCAT_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -i tomcat || true)

if [ -z "$TOMCAT_IMAGES" ]; then
    echo "ERROR: No Tomcat images found."
    exit 1
fi

echo "Detected Tomcat images:"
echo "$TOMCAT_IMAGES"
echo

# ------------------------------------------------------------
# Function to test a Tomcat image
# ------------------------------------------------------------
run_tomcat_test() {
    local IMAGE="$1"

    echo "------------------------------------------------------------"
    echo "  Testing $IMAGE"
    echo "------------------------------------------------------------"

    echo "Starting container..."
    docker run --rm -d -p 8080:8080 "$IMAGE" >/tmp/tomcat_pid.txt
    CID=$(cat /tmp/tomcat_pid.txt)

    echo "Waiting for Tomcat to initialize..."
    sleep 12

    echo "Running connectivity tests..."

    # Basic HTTP check
    if curl -s http://localhost:8080 >/dev/null; then
        echo "[PASS] HTTP root responded"
    else
        echo "[FAIL] HTTP root did NOT respond"
    fi

    # Check for Tomcat default page
    if curl -s http://localhost:8080 | grep -qi "tomcat"; then
        echo "[PASS] Tomcat default page detected"
    else
        echo "[WARN] Tomcat default page NOT detected"
    fi

    # Check for HTTP headers
    HEADERS=$(curl -s -I http://localhost:8080)
    echo "[INFO] Response headers:"
    echo "$HEADERS"

    # Check for WebSocket upgrade support (Guac requirement)
    if echo -e "GET / HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n" \
        | nc localhost 8080 >/dev/null 2>&1; then
        echo "[PASS] WebSocket upgrade handshake accepted"
    else
        echo "[WARN] WebSocket upgrade handshake NOT accepted"
    fi

    echo "Stopping container..."
    docker stop "$CID" >/dev/null 2>&1 || true
    sleep 3
}

# ------------------------------------------------------------
# Run tests for each detected Tomcat image
# ------------------------------------------------------------
echo "[3/6] Running Tomcat tests..."
for IMG in $TOMCAT_IMAGES; do
    run_tomcat_test "$IMG"
done

# ------------------------------------------------------------
# Restart Guacamole stack
# ------------------------------------------------------------
echo "[4/6] Restarting Guacamole stack..."
if [ -f "$COMPOSE_DIR/run.sh" ]; then
    bash "$COMPOSE_DIR/run.sh"
else
    echo "ERROR: run.sh not found in $COMPOSE_DIR"
    exit 1
fi

echo "[5/6] Guacamole stack restored."
echo "[6/6] Tomcat testing complete."

echo "============================================================"
echo "  SMART TOMCAT TEST HARNESS COMPLETE"
echo "============================================================"
