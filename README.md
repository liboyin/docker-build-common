# docker-build-common

Shared shell helpers for the `apt`, `pip` and `uv` steps of a Docker image build, with
optional caching-proxy support.

These scripts were copy-pasted across several projects and hand-synced, which drifted:
fixes reached some repos and not others. They now live here once and are pinned by each
consumer.

## Scripts

### `apt_install.sh <package>...`

Installs the given packages with `--no-install-recommends`, then removes the package
lists and caches so nothing is left in the layer. Fails if given no packages.

Reads `APT_PROXY`. When it is non-empty, `/etc/apt/apt.conf.d/01proxy` is written before
`apt-get update`. When it is unset **or empty**, no proxy is configured — so a consumer
can always pass the build arg and let an empty value mean "no proxy".

### `pip_install.sh [lock-file]`

Writes `$HOME/.pip/pip.conf` with the settings that suit an image build (no cache, no
bytecode, no version check), then installs the lock file if one is named.

A named lock file **must exist and be non-empty**, otherwise the script fails. Silently
skipping a missing lock file is what previously let images ship with unpinned
dependencies. Omit the argument entirely for projects that have no lock file.

`break-system-packages = true` is always set. It is required on images whose Python is
the distro's, and inert on images without an `EXTERNALLY-MANAGED` marker.

Reads `PYPI_PROXY`. When non-empty, `index-url` and a `trusted-host` derived from its
hostname are appended to `pip.conf`.

### `uv_install.sh <venv-dir> [uv-export-option]...`

Installs a [uv](https://docs.astral.sh/uv/) project's locked dependencies into a virtual
environment. Run it from the project directory, which must contain `uv.lock`; otherwise
the script fails. The venv is created if absent, from whatever interpreter uv selects for
the project (`.python-version`, `UV_PYTHON`, ...).

The lock is exported with `uv export --frozen --no-default-groups` plus the given options,
and `uv pip sync` then makes the venv match that export exactly, verifying every artifact
hash the lock records. Dependency groups, including `dev`, are left out unless selected
with `--group`. Pass `--no-emit-project` to install dependencies only; without it the
project itself is installed too, editable unless `--no-editable` is passed. Bytecode is
not precompiled and no uv cache is kept, matching `pip_install.sh`.

The helper exports instead of running `uv sync`, because a lock resolved against PyPI
does not survive a proxy index: `uv sync --locked` reports the lock as stale when the
index URL differs, and `uv sync --frozen` downloads from the file URLs recorded in the
lock, bypassing the proxy. A side effect is that the build does not check that the lock
matches `pyproject.toml`; run `uv sync --locked` or `uv lock --check` where PyPI is
reachable, for example in the dev container.

uv itself is not provided: put it on `PATH` first, which also pins its version.

Reads `PYPI_PROXY`. When non-empty, it becomes `UV_DEFAULT_INDEX`, and its hostname
becomes `UV_INSECURE_HOST`, matching `pip_install.sh`'s `trusted-host`. Both are set for
the script's own uv processes only. Nothing is written to uv configuration, because a
persistent index would make later `uv lock` runs record the proxy URL in the lock.

## Use from a project

Compose names this repo as an additional build context, pinned to a tag:

```yaml
services:
  app:
    build:
      context: .
      additional_contexts:
        # Set BUILD_COMMON_CONTEXT in .env to a local clone to build offline, or to
        # test a change here before tagging it.
        build_common: "${BUILD_COMMON_CONTEXT:-https://github.com/liboyin/docker-build-common.git#v1.0.0}"
      args:
        # Optional caching proxies, interpolated from .env. Default to empty (direct
        # internet), so the image builds on any machine without extra configuration.
        APT_PROXY: ${APT_PROXY:-}
        PYPI_PROXY: ${PYPI_PROXY:-}
```

The Dockerfile mounts that context for the length of a `RUN` and calls the helpers:

```dockerfile
ARG APT_PROXY
ARG PYPI_PROXY

RUN --mount=type=bind,from=build_common,target=/build-common \
    /build-common/apt_install.sh curl ffmpeg git
RUN --mount=type=bind,from=build_common,target=/build-common \
    /build-common/pip_install.sh requirements.txt
```

A uv project copies uv from its pinned image and installs in two steps, so a source
change does not invalidate the dependency layer:

```dockerfile
COPY --from=ghcr.io/astral-sh/uv:<version> /uv /usr/local/bin/uv

COPY pyproject.toml uv.lock .python-version ./
RUN --mount=type=bind,from=build_common,target=/build-common \
    /build-common/uv_install.sh /opt/venv --no-emit-project
COPY . .
RUN --mount=type=bind,from=build_common,target=/build-common \
    /build-common/uv_install.sh /opt/venv
ENV PATH=/opt/venv/bin:$PATH
```

A bind mount rather than `COPY` because the helpers are build-time only: nothing is
added to a layer, nothing is left in the shipped image, and there is no destination
path to collide with a dev container's workspace mount. The mounted content still
counts toward the `RUN` cache key, so bumping the pin still rebuilds. `COPY --from=build_common`
works too — the helpers are stored mode `755` and the exec bit survives — if a project
would rather have them on disk.

Pass apt packages as separate arguments, never as one quoted string.

Anything project-specific — extra `apt` steps, bootstrapping pip, `pip install -e .` —
stays in the project's own Dockerfile as separate `RUN` lines.

### Pinning

Pin to an immutable tag for readability, or to a full 40-character commit SHA. Never
pin to a branch or a floating major: that would silently change every consumer's image.

BuildKit keys its cache on the *resolved* commit, so a moved tag correctly invalidates
the cache rather than serving a stale one. The cost is that a non-SHA ref is re-resolved
against the remote on every build, making `github.com` reachability a hard build
dependency — one that `APT_PROXY`/`PYPI_PROXY` do **not** cover, because BuildKit
fetches the context itself. A full SHA needs no such lookup once the snapshot is warm,
and `BUILD_COMMON_CONTEXT` pointed at a local clone avoids the network entirely.

The repository must be public, or BuildKit needs Git credentials on every machine that
builds. It contains no secrets: proxy addresses live in each project's gitignored `.env`.

## Tests

`tests/run.sh` runs throwaway containers and exercises the scripts with the proxy set,
unset, and empty, asserting on the generated `01proxy` and `pip.conf`. The
`uv_install.sh` cases put `tests/stub-uv/uv` first on `PATH`, which records the
arguments and environment the helper passes to uv without touching the network.
Requires Docker.
