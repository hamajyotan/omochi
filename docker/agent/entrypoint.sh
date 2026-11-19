#!/bin/sh
set -eu

# Link pre-installed tools from read-only /opt/mise into writable MISE_DATA_DIR
# so that both baked-in Ruby versions and ad-hoc `mise install` work under --read-only.
if [ -d /opt/mise/installs ] && [ -n "${MISE_DATA_DIR:-}" ]; then
  mkdir -p "${MISE_DATA_DIR}/installs"
  for tool_dir in /opt/mise/installs/*; do
    [ -d "$tool_dir" ] || continue
    tool_name="$(basename "$tool_dir")"
    mkdir -p "${MISE_DATA_DIR}/installs/${tool_name}"
    for version_dir in "${tool_dir}"/*; do
      [ -e "$version_dir" ] || continue
      version_name="$(basename "$version_dir")"
      target="${MISE_DATA_DIR}/installs/${tool_name}/${version_name}"
      if [ ! -e "$target" ]; then
        ln -s "$version_dir" "$target"
      fi
    done
  done
  mise reshim >/dev/null 2>&1 || true
fi

exec "$@"
