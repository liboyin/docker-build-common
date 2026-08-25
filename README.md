# docker-build-common

Shared shell helpers for the `apt` and `pip` steps of a Docker image build, with
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

## Use from a project

Compose names this repo as an additional build context, pinned to a tag:

```yaml
services:
  app:
    build:
      context: .
      additional_contexts:
        build_common: https://github.com/liboyin/docker-build-common.git#v1.0.0
      args:
        # Optional caching proxies, interpolated from .env. Default to empty (direct
        # internet), so the image builds on any machine without extra configuration.
        APT_PROXY: ${APT_PROXY:-}
        PYPI_PROXY: ${PYPI_PROXY:-}
```

The Dockerfile copies the helpers out of that context and calls them:

```dockerfile
ARG APT_PROXY
ARG PYPI_PROXY

COPY --from=build_common apt_install.sh pip_install.sh /build-common/

RUN /build-common/apt_install.sh curl ffmpeg git
RUN /build-common/pip_install.sh requirements.txt
```

Copy the helpers **outside** the project workspace when the project has a dev container
that bind-mounts the host workspace over it, or the mount will shadow them.

Anything project-specific — extra `apt` steps, bootstrapping pip, `pip install -e .` —
stays in the project's own Dockerfile as separate `RUN` lines.

Pin to a tag for readability, or to a full 40-character commit SHA where the build must
be reproducible. A moved tag resolves to a different commit and correctly invalidates
the build cache; the tag itself is mutable, which is the trade-off.

The repository must be public, or BuildKit needs Git credentials on every machine that
builds. It contains no secrets: proxy addresses live in each project's gitignored `.env`.

## Tests

`tests/run.sh` builds a throwaway image and exercises both scripts with the proxy set,
unset, and empty, asserting on the generated `01proxy` and `pip.conf`. Requires Docker.
