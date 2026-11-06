#!/bin/bash
#
# Install a uv project's locked dependencies into a virtual environment during a Docker
# image build, optionally through a PyPI proxy, and leave no uv cache behind in the layer.
#
# Usage:
#   uv_install.sh <venv-dir> [uv-export-option]...
#
# Run from the project directory, which must contain uv.lock. The venv is created if it
# does not exist yet, using whatever interpreter uv selects for the project (for example
# from .python-version or UV_PYTHON). The lock is exported with `uv export --frozen
# --no-default-groups` plus the given options, and `uv pip sync` then makes the venv match
# that export exactly, verifying every artifact hash the lock records.
#
# Pass --no-emit-project to install dependencies only, so a source change does not
# invalidate that layer; call the helper again after copying the source to install the
# project itself (editable unless --no-editable is passed). Groups and extras are selected
# with the usual export options, e.g. --group test or --extra gpu.
#
# The lock is exported rather than installed with `uv sync`, because a lock resolved
# against PyPI does not survive a proxy index: `uv sync --locked` reports the lock as stale
# when the index URL differs, and `uv sync --frozen` downloads from the file URLs recorded
# in the lock, bypassing the proxy.
#
# Environment:
#   PYPI_PROXY  Optional PyPI proxy index URL, e.g. http://192.168.0.4:3141/root/pypi/+simple/.
#               Ignored when unset or empty, so the build falls back to PyPI itself. Applied
#               to this script's uv processes only; nothing is written to uv configuration,
#               because a persistent index would leak into later `uv lock` runs.

set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "$0: expected a virtual environment directory" >&2
    exit 2
fi
venv_dir=$1
shift

# The consumer provides uv (for example by copying it from the ghcr.io/astral-sh/uv
# image), so it pins the uv version; say so rather than dying on "uv: not found".
if ! command -v uv > /dev/null; then
    echo "$0: uv is not on PATH; provide it before calling this script" >&2
    exit 2
fi

if [ ! -f uv.lock ]; then
    echo "$0: no uv.lock in $(pwd); run this script from the project directory" >&2
    exit 1
fi

# Configure the PyPI proxy (skipped when PYPI_PROXY is unset or empty). The insecure host
# mirrors pip_install.sh's trusted-host, so both helpers accept the same proxies.
if [ -n "${PYPI_PROXY:-}" ]; then
    export UV_DEFAULT_INDEX="$PYPI_PROXY"
    UV_INSECURE_HOST=$(echo "$PYPI_PROXY" | sed -E 's|https?://([^:/]+).*|\1|')
    export UV_INSECURE_HOST
    echo "Using PyPI proxy: $UV_DEFAULT_INDEX (insecure host $UV_INSECURE_HOST)"
fi
export UV_NO_CACHE=1

uv venv --allow-existing "$venv_dir"

requirements=$(mktemp)
trap 'rm -f "$requirements"' EXIT
uv export --frozen --no-default-groups --format requirements.txt --no-header \
    --output-file "$requirements" "$@"

# A requirement line starts in the first column; hashes and comments are indented or '#'.
if ! grep -qE '^[^#[:space:]]' "$requirements"; then
    echo "$0: the export selects no packages, skipping install"
    exit 0
fi
uv pip sync --python "$venv_dir/bin/python" "$requirements"
