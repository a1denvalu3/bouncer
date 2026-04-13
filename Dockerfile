FROM node:20-slim

# Install necessary tools: git, github cli, cron, curl
RUN apt-get update && apt-get install -y \
    git \
    curl \
    cron \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install gh -y

# Install opencode via NPM
RUN npm install -g opencode-ai

WORKDIR /app

# Copy our review script
COPY review.sh /app/review.sh
RUN chmod +x /app/review.sh

# Copy an entrypoint to set up the dynamic cron schedule
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Start cron in the foreground via entrypoint
CMD ["/app/entrypoint.sh"]
