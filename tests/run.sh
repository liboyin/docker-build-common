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

echo "== uv_install.sh (stub uv) =="

# Each snippet runs the helper from a fresh project directory holding an empty uv.lock,
# with the stub uv first on PATH; the stub's log shows what the helper asked uv to do.
UV_SETUP='cd "$(mktemp -d)" && touch uv.lock && export PATH=/build-common/tests/stub-uv:$PATH STUB_UV_LOG=/tmp/uv.log'
UV_RUN='/build-common/uv_install.sh /venv'

unset APT_PROXY PYPI_PROXY

assert_eq "uv_install.sh rejects a missing venv directory" 2 \
    "$(in_container "$UV_SETUP; /build-common/uv_install.sh >/dev/null 2>&1; echo \$?")"

assert_eq "uv_install.sh fails early when uv is not on PATH" 2 \
    "$(in_container "cd \"\$(mktemp -d)\" && touch uv.lock; $UV_RUN >/dev/null 2>&1; echo \$?")"

assert_eq "uv_install.sh rejects a project directory without uv.lock" 1 \
    "$(in_container "$UV_SETUP && rm uv.lock; $UV_RUN >/dev/null 2>&1; echo \$?")"

assert_eq "uv_install.sh creates the venv, exports the frozen lock and syncs it" \
    "args: venv --allow-existing /venv
args: export --frozen --no-default-groups --format requirements.txt --no-header --output-file EXPORT --no-emit-project
args: pip sync --python /venv/bin/python EXPORT" \
    "$(in_container "$UV_SETUP; $UV_RUN --no-emit-project >/dev/null && export_file=\$(sed -n 's/^export-file: //p' /tmp/uv.log) && grep '^args:' /tmp/uv.log | sed \"s|\$export_file|EXPORT|g\"")"

assert_eq "uv_install.sh removes its temporary export file" ABSENT \
    "$(in_container "$UV_SETUP; $UV_RUN >/dev/null && f=\$(sed -n 's/^export-file: //p' /tmp/uv.log) && [ -n \"\$f\" ] && { [ -e \"\$f\" ] && echo PRESENT || echo ABSENT; }")"

assert_eq "uv_install.sh skips the sync when the export selects no packages" \
    "0 0" \
    "$(in_container "$UV_SETUP; STUB_EXPORT_EMPTY=1 $UV_RUN >/dev/null; echo \$? \$(grep -c '^args: pip sync' /tmp/uv.log)")"

assert_eq "uv_install.sh disables the uv cache and sets no index when PYPI_PROXY is unset" \
    "env: UV_DEFAULT_INDEX=<unset> UV_INSECURE_HOST=<unset> UV_NO_CACHE=1" \
    "$(in_container "$UV_SETUP; $UV_RUN >/dev/null; grep '^env:' /tmp/uv.log | sort -u")"

export PYPI_PROXY=""
assert_eq "empty PYPI_PROXY sets no uv index" \
    "env: UV_DEFAULT_INDEX=<unset> UV_INSECURE_HOST=<unset> UV_NO_CACHE=1" \
    "$(in_container "$UV_SETUP; $UV_RUN >/dev/null; grep '^env:' /tmp/uv.log | sort -u")"

export PYPI_PROXY="http://192.168.0.4:3141/root/pypi/+simple/"
assert_eq "set PYPI_PROXY becomes the uv default index with a derived insecure host" \
    "env: UV_DEFAULT_INDEX=http://192.168.0.4:3141/root/pypi/+simple/ UV_INSECURE_HOST=192.168.0.4 UV_NO_CACHE=1" \
    "$(in_container "$UV_SETUP; $UV_RUN >/dev/null; grep '^env:' /tmp/uv.log | sort -u")"

assert_eq "uv_install.sh writes no persistent uv configuration" ABSENT \
    "$(in_container "$UV_SETUP; $UV_RUN >/dev/null; [ -e /etc/uv ] || [ -e \"\$HOME/.config/uv\" ] && echo PRESENT || echo ABSENT")"
unset PYPI_PROXY

echo
if [ "$failures" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failures check(s) failed."
fi
exit $((failures > 0))
