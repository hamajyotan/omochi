# Antigravity Agent Container Image for omochi (Phase 7)
FROM python:3.12-slim

# Install system dependencies needed for git operations, build tools, and process execution
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    build-essential \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Google Antigravity Python SDK
RUN pip install --no-cache-dir google-antigravity

# Create workspace and home directories with wide permissions for non-root runtime
RUN mkdir -p /workspace /opt/omochi /home/agent && chmod 777 /workspace /opt/omochi /home/agent

ENV HOME=/home/agent
WORKDIR /workspace

# Container is started non-root by DockerRunner (--user uid:gid)
CMD ["python3", "/opt/omochi/agent_runner"]
