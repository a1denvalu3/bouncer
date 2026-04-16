FROM node:20-slim

# Install necessary tools: git, github cli, cron, curl, systemd-container, rsync, gettext-base (for envsubst)
RUN apt-get update && apt-get install -y \
    git \
    curl \
    cron \
    jq \
    systemd-container \
    rsync \
    gettext-base \
    sudo \
    default-jdk
    

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

# Copy our review scripts
COPY prompt_template.txt /app/prompt_template.txt
COPY opencode_runner.sh /app/opencode_runner.sh
COPY review.sh /app/review.sh
RUN chmod +x /app/review.sh /app/opencode_runner.sh

# Copy an entrypoint to set up the dynamic cron schedule
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Start cron in the foreground via entrypoint
CMD ["/app/entrypoint.sh"]
