FROM node:22-slim

RUN apt-get update -qq && apt-get install -y -qq git curl jq \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && cp /root/.local/bin/claude /usr/local/bin/claude \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
