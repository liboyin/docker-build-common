#!/bin/bash
#
# Install apt packages during a Docker image build, optionally through a caching proxy,
# and leave no package lists or caches behind in the layer.
#
# Usage:
#   apt_install.sh <package>...
#
# Environment:
#   APT_PROXY  Optional apt caching proxy URL, e.g. http://192.168.0.4:3142.
#              Ignored when unset or empty, so the build falls back to the public
#              archives on any machine.

set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "$0: expected at least one package name" >&2
    exit 2
fi

# Configure the APT proxy (skipped when APT_PROXY is unset or empty)
if [ -n "${APT_PROXY:-}" ]; then
    APT_CONF_PATH=/etc/apt/apt.conf.d/01proxy
    echo "Acquire::http::Proxy \"$APT_PROXY\";" > "$APT_CONF_PATH"
    cat "$APT_CONF_PATH"
fi

apt-get update
apt-get install -y --no-install-recommends "$@"
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
