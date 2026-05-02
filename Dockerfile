FROM node:20-slim

# Install necessary tools: git, github cli, cron, jq, systemd-container, rsync, gettext-base, etc.
RUN apt-get update && apt-get install -y \
    git \
    curl \
    cron \
    jq \
    systemd-container \
    rsync \
    gettext-base \
    sudo \
    default-jdk \
    bridge-utils \
    iptables \
    dnsmasq \
    isc-dhcp-client \
    iproute2 \
    sqlcipher

# Install GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install gh -y

# Install opencode via NPM
RUN npm install -g opencode-ai

# Copy the entire filesystem to /nspawn-root for the ephemeral nspawn containers
RUN mkdir /nspawn-root && rsync -a --exclude=/dev --exclude=/proc --exclude=/sys --exclude=/tmp --exclude=/run --exclude=/mnt --exclude=/media --exclude=/lost+found --exclude=/nspawn-root / /nspawn-root/ && mkdir -p /nspawn-root/dev /nspawn-root/proc /nspawn-root/sys /nspawn-root/tmp /nspawn-root/run

WORKDIR /app

# Copy our application scripts and templates
COPY scripts /app/scripts
COPY templates /app/templates
RUN chmod +x /app/scripts/*.sh

# Start cron in the foreground via entrypoint
CMD ["/app/scripts/entrypoint.sh"]
