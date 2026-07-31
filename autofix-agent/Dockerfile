# Section 30: containerized AutoFix Agent Runner.
#
# Contains: JDK 21 (for ./gradlew), git, GitHub CLI, Copilot CLI (pinned
# version), Python 3 + FastAPI/Uvicorn.
#
# Explicitly does NOT contain: Jira/PostgreSQL/Elasticsearch credentials,
# the Docker socket/CLI, an SSH server, or n8n admin credentials (Section
# 6). Runs as a non-root user. Only port 8090 is exposed.

FROM eclipse-temurin:21-jdk-jammy

ARG GH_CLI_VERSION=2.63.2
ARG NODE_MAJOR=20
ARG COPILOT_CLI_VERSION=1.0.76

ENV DEBIAN_FRONTEND=noninteractive \
    AUTOFIX_WORKSPACE_ROOT=/workspace \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      gnupg \
      git \
      jq \
      python3 \
      python3-pip \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js (required to install the Copilot CLI npm package) -------------
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI (pinned) -----------------------------------------------------
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_CLI_VERSION}/gh_${GH_CLI_VERSION}_linux_$(dpkg --print-architecture).tar.gz" \
      -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && mv /tmp/gh_${GH_CLI_VERSION}_linux_*/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_CLI_VERSION}_linux_*

# --- Copilot CLI (pinned) ----------------------------------------------------
RUN npm install -g @github/copilot@${COPILOT_CLI_VERSION}

# --- Python deps --------------------------------------------------------------
COPY requirements.txt /app/requirements.txt
RUN pip3 install --no-cache-dir -r /app/requirements.txt

# --- Non-root user -------------------------------------------------------------
RUN groupadd --gid 10001 autofix \
    && useradd --uid 10001 --gid autofix --create-home --shell /bin/bash autofix \
    && mkdir -p /workspace/state /workspace/logs /workspace/current \
    && chown -R autofix:autofix /workspace /app

WORKDIR /app
COPY --chown=autofix:autofix server.py execute-job.sh entrypoint.sh /app/
COPY --chown=autofix:autofix lib/ /app/lib/
COPY --chown=autofix:autofix prompts/ /app/prompts/
COPY --chown=autofix:autofix schemas/ /app/schemas/

RUN chmod +x /app/entrypoint.sh /app/execute-job.sh /app/lib/*.sh

USER autofix

EXPOSE 8090

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:8090/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
