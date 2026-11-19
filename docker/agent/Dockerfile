# Antigravity Agent Container Image for omochi (Phase 7)
# Build: docker build -t omochi-agent:antigravity docker/agent
FROM python:3.12-slim

ARG RUBY_VERSION=4.0.10

# Install system dependencies needed for git operations, Ruby (mise / ruby-build),
# C-extension gems, and SQLite (omochi runtime & test suite).
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    build-essential \
    ca-certificates \
    pkg-config \
    autoconf \
    bison \
    libssl-dev \
    libyaml-dev \
    libffi-dev \
    zlib1g-dev \
    libreadline-dev \
    libgmp-dev \
    libsqlite3-dev \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Install Google Antigravity Python SDK
RUN pip install --no-cache-dir google-antigravity

# Install mise for managing Ruby versions (pre-baked + ad-hoc installs)
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Configure mise globally:
# - Prefer precompiled Ruby binaries when available (faster ad-hoc installs)
# - Trust /workspace/.ruby-version without interactive prompts
# - Pre-bake default Ruby into read-only /opt/mise during build
ENV MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml \
    MISE_CACHE_DIR=/tmp/mise-cache \
    MISE_STATE_DIR=/tmp/mise-state
RUN mkdir -p /etc/mise /opt/mise && \
    printf '%s\n' \
      '[settings]' \
      'ruby.compile = false' \
      'idiomatic_version_file_enable_tools = ["ruby"]' \
      'trusted_config_paths = ["/workspace"]' \
      > /etc/mise/config.toml && \
    MISE_DATA_DIR=/opt/mise mise use -g "ruby@${RUBY_VERSION}" && \
    MISE_DATA_DIR=/opt/mise mise reshim && \
    chmod -R a+rX /opt/mise /etc/mise

# At runtime, /home/agent and /tmp are writable tmpfs mounts under --read-only.
# Point MISE_DATA_DIR and Bundler/Gem paths to writable locations while entrypoint
# symlinks pre-installed tools from /opt/mise/installs.
ENV HOME=/home/agent \
    MISE_DATA_DIR=/home/agent/.local/share/mise \
    GEM_HOME=/tmp/gems \
    BUNDLE_PATH=/tmp/bundle \
    PATH=/home/agent/.local/share/mise/shims:/opt/mise/shims:/tmp/gems/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Create workspace, runtime, and home directories with wide permissions for non-root runtime
RUN mkdir -p /workspace /opt/omochi /home/agent && chmod 777 /workspace /opt/omochi /home/agent

COPY --chmod=755 entrypoint.sh /usr/local/bin/omochi-entrypoint.sh

WORKDIR /workspace

# Container is started non-root by DockerRunner (--user uid:gid)
ENTRYPOINT ["/usr/local/bin/omochi-entrypoint.sh"]
CMD ["python3", "/opt/omochi/agent_runner"]
