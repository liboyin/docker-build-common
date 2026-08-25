#!/bin/bash
#
# Smoke tests for the shared build helpers. Requires Docker.
#
# Each case runs a helper inside a throwaway container and asserts on the configuration
# it generates, ignoring whether the subsequent network install succeeded. The proxy
# wiring is the logic worth protecting, and its behaviour must hold whether or not an
# index is reachable.
#
# Usage:
#   tests/run.sh            # uses python:3.14-slim
#   TEST_IMAGE=... tests/run.sh

set -uo pipefail

IMAGE=${TEST_IMAGE:-python:3.14-slim}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PIP_CONF=/root/.pip/pip.conf
APT_CONF=/etc/apt/apt.conf.d/01proxy

failures=0

# Pull up front so a first-run pull cannot interleave with a case.
docker pull -q "$IMAGE" > /dev/null

# Runs a shell snippet in a container with the helpers mounted read-only at /build-common,
# forwarding APT_PROXY and PYPI_PROXY only when they are set in this shell. Only the
# snippet's stdout is returned: docker's own chatter would otherwise be compared against
# the expected value.
in_container() {
    docker run --rm -v "$REPO_DIR:/build-common:ro" \
        ${APT_PROXY+-e APT_PROXY} ${PYPI_PROXY+-e PYPI_PROXY} \
        "$IMAGE" bash -c "$1" 2>/dev/null
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        echo "      expected: $2"
        echo "      actual:   $3"
        failures=$((failures + 1))
    fi
}

echo "== apt proxy configuration =="

unset APT_PROXY PYPI_PROXY
assert_eq "unset APT_PROXY writes no apt proxy config" ABSENT \
    "$(in_container "/build-common/apt_install.sh ca-certificates >/dev/null 2>&1; [ -e $APT_CONF ] && echo PRESENT || echo ABSENT")"

export APT_PROXY=""
assert_eq "empty APT_PROXY writes no apt proxy config" ABSENT \
    "$(in_container "/build-common/apt_install.sh ca-certificates >/dev/null 2>&1; [ -e $APT_CONF ] && echo PRESENT || echo ABSENT")"

export APT_PROXY="http://127.0.0.1:1"
assert_eq "set APT_PROXY writes the proxy into the apt config" \
    'Acquire::http::Proxy "http://127.0.0.1:1";' \
    "$(in_container "/build-common/apt_install.sh ca-certificates >/dev/null 2>&1; cat $APT_CONF")"

echo "== pip proxy configuration =="

unset APT_PROXY PYPI_PROXY
assert_eq "unset PYPI_PROXY leaves pip.conf without an index-url" "" \
    "$(in_container "/build-common/pip_install.sh >/dev/null; grep '^index-url' $PIP_CONF")"

export PYPI_PROXY=""
assert_eq "empty PYPI_PROXY leaves pip.conf without an index-url" "" \
    "$(in_container "/build-common/pip_install.sh >/dev/null; grep '^index-url' $PIP_CONF")"

export PYPI_PROXY="http://192.168.0.4:3141/root/pypi/+simple/"
assert_eq "set PYPI_PROXY writes index-url and a derived trusted-host" \
    "index-url = http://192.168.0.4:3141/root/pypi/+simple/
trusted-host = 192.168.0.4" \
    "$(in_container "/build-common/pip_install.sh >/dev/null; grep -E '^(index-url|trusted-host)' $PIP_CONF")"

unset PYPI_PROXY
assert_eq "pip.conf always sets break-system-packages" "break-system-packages = true" \
    "$(in_container "/build-common/pip_install.sh >/dev/null; grep '^break-system-packages' $PIP_CONF")"

echo "== argument validation =="

unset APT_PROXY PYPI_PROXY

assert_eq "apt_install.sh rejects an empty package list" 2 \
    "$(in_container "/build-common/apt_install.sh >/dev/null 2>&1; echo \$?")"

assert_eq "pip_install.sh rejects a missing lock file" 1 \
    "$(in_container "/build-common/pip_install.sh /nope.txt >/dev/null 2>&1; echo \$?")"

assert_eq "pip_install.sh rejects an empty lock file" 1 \
    "$(in_container "touch /empty.txt; /build-common/pip_install.sh /empty.txt >/dev/null 2>&1; echo \$?")"

assert_eq "pip_install.sh rejects more than one lock file" 2 \
    "$(in_container "/build-common/pip_install.sh a.txt b.txt >/dev/null 2>&1; echo \$?")"

assert_eq "pip_install.sh with no lock file configures pip and succeeds" 0 \
    "$(in_container "/build-common/pip_install.sh >/dev/null 2>&1; echo \$?")"

echo
if [ "$failures" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failures check(s) failed."
fi
exit $((failures > 0))
