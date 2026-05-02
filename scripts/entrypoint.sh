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

# Run database migrations before starting the poller
/app/scripts/migrate_db.sh

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
