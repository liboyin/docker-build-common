#!/bin/bash
#
# Configure pip for use during a Docker image build, optionally against a proxy index,
# and install pinned dependencies from a lock file.
#
# Usage:
#   pip_install.sh [lock-file]
#
# Passing a lock file installs it; the file must exist and be non-empty, otherwise the
# build fails rather than silently producing an image with unpinned dependencies.
# Omitting the argument configures pip only, for projects that have no lock file.
#
# Environment:
#   PYPI_PROXY  Optional PyPI proxy index URL, e.g. http://192.168.0.4:3141/root/pypi/+simple/.
#               Ignored when unset or empty, so the build falls back to PyPI itself.

set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "$0: expected at most one lock file, got $#" >&2
    exit 2
fi

PIP_CONF_PATH=$HOME/.pip/pip.conf
mkdir -p "$(dirname "$PIP_CONF_PATH")"
# break-system-packages is inert on images without an EXTERNALLY-MANAGED marker, so it is
# set unconditionally rather than per-project.
cat <<EOF > "$PIP_CONF_PATH"
[global]
break-system-packages = true
disable-pip-version-check = true
no-cache-dir = true
no-compile = true
root-user-action = ignore
EOF

# Configure the PyPI proxy (skipped when PYPI_PROXY is unset or empty)
if [ -n "${PYPI_PROXY:-}" ]; then
    cat <<EOF >> "$PIP_CONF_PATH"
index-url = $PYPI_PROXY
trusted-host = $(echo "$PYPI_PROXY" | sed -E 's|https?://([^:/]+).*|\1|')
EOF
fi

cat "$PIP_CONF_PATH"

if [ "$#" -eq 1 ]; then
    if [ ! -s "$1" ]; then
        echo "$0: lock file '$1' is missing or empty" >&2
        exit 1
    fi
    pip install -r "$1"
fi

# Remove pip cache
pip_cache_dirs=(
    "/tmp/pip-tmp"
    "$HOME/.cache/pip"
)
for dir_path in "${pip_cache_dirs[@]}"; do
    if [ -d "$dir_path" ]; then
        echo "Removing pip cache dir: $dir_path"
        rm -rf "$dir_path"
    fi
done
