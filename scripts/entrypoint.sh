#!/bin/bash
set -e

# Make sure opencode is in the PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.opencode/bin:$PATH"

# Mount tmpfs on /run so systemd-nspawn can create necessary directories
if ! mountpoint -q /run; then
    mount -t tmpfs tmpfs /run
fi

# Set up isolated network bridge for nspawn containers
if ! ip link show br-nspawn >/dev/null 2>&1; then
    ip link add name br-nspawn type bridge
    ip addr add 10.200.0.1/16 dev br-nspawn
    ip link set br-nspawn up
    iptables -t nat -A POSTROUTING -s 10.200.0.0/16 -j MASQUERADE
    echo 1 > /proc/sys/net/ipv4/ip_forward
    # Start dnsmasq to provide DHCP on the bridge
    dnsmasq --interface=br-nspawn --bind-interfaces --dhcp-range=10.200.0.2,10.200.255.254,255.255.0.0,12h
fi

# Inject per-token pricing into opencode's global config for the nspawn sandboxes.
# Subscription-plan providers (e.g. kimi-for-coding) carry $0 pricing in
# models.dev, so `opencode stats` always reports Total Cost $0.00 and no cost
# metrics reach the database. The override below supplies API-equivalent list
# prices (per 1M tokens). It is applied automatically for kimi-for-coding/k3
# (Kimi K3 list prices as of Aug 2026), or for any explicitly configured
# OPENCODE_MODEL when at least one MODEL_COST_* variable is set.
# When OPENCODE_MODEL is unset the scripts pick their own defaults, so there
# is nothing to key the override to and it is skipped.
APPLY_COST_OVERRIDE=0
if [ -n "$OPENCODE_MODEL" ]; then
    MODEL_PROVIDER="${OPENCODE_MODEL%%/*}"
    MODEL_ID="${OPENCODE_MODEL#*/}"

    if [ -n "$MODEL_COST_INPUT_PER_MTOK" ] || [ -n "$MODEL_COST_OUTPUT_PER_MTOK" ] || [ -n "$MODEL_COST_CACHE_READ_PER_MTOK" ]; then
        APPLY_COST_OVERRIDE=1
    elif [ "$MODEL_PROVIDER" = "kimi-for-coding" ] && [ "$MODEL_ID" = "k3" ]; then
        APPLY_COST_OVERRIDE=1
    fi
fi

if [ "$APPLY_COST_OVERRIDE" = "1" ]; then
    export MODEL_PROVIDER MODEL_ID
    export MODEL_COST_INPUT_PER_MTOK=${MODEL_COST_INPUT_PER_MTOK:-3.00}
    export MODEL_COST_OUTPUT_PER_MTOK=${MODEL_COST_OUTPUT_PER_MTOK:-15.00}
    export MODEL_COST_CACHE_READ_PER_MTOK=${MODEL_COST_CACHE_READ_PER_MTOK:-0.30}
    mkdir -p /nspawn-root/root/.config/opencode
    envsubst < /app/templates/opencode_config.json > /nspawn-root/root/.config/opencode/opencode.json
    echo "Model cost override for ${OPENCODE_MODEL}: \$${MODEL_COST_INPUT_PER_MTOK}/\$${MODEL_COST_OUTPUT_PER_MTOK}/\$${MODEL_COST_CACHE_READ_PER_MTOK} per 1M tokens (input/output/cache_read)"
fi

# Run database migrations before starting the poller
/app/scripts/migrate_db.sh

# If arguments are passed, execute them and exit
if [ $# -gt 0 ]; then
    echo "Executing command: $@"
    exec "$@"
fi

# Default sleep duration to 60 seconds if not provided
SLEEP_DURATION=${SLEEP_DURATION:-60}

echo "Starting PR reviewer in a loop with a ${SLEEP_DURATION}s sleep interval..."

while true; do
    /app/scripts/review.sh 2>&1
    
    # Check for active nspawn containers before sleeping
    ACTIVE_NSPAWNS=$(ps ww -eo cmd | grep '[s]ystemd-nspawn' | grep -o 'target-repo-[^ ]*' | sed 's/target-repo-//' | sort -u || true)
    
    if [ -n "$ACTIVE_NSPAWNS" ]; then
        echo "Active PR reviews (nspawn containers) running:"
        for repo_pr in $ACTIVE_NSPAWNS; do
            # Format output neatly, separating repo and PR number
            REPO=$(echo "$repo_pr" | rev | cut -d'-' -f2- | rev)
            PR=$(echo "$repo_pr" | rev | cut -d'-' -f1 | rev)
            echo "  - Repo: ${REPO}, PR: #${PR}"
        done
    else
        echo "No active PR reviews currently running."
    fi

    echo "Sleeping for ${SLEEP_DURATION} seconds before next run..."
    sleep "${SLEEP_DURATION}"
done
