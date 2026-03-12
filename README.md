# Upstream Binary Builds

This repository is a reusable template for building upstream software from source and publishing the resulting binaries as GitHub Release assets.

It is meant for cases like these:

- An upstream project ships source code but no ready-to-use binaries.
- You want your own reproducible rebuilds instead of depending on upstream binaries.
- You need one place to maintain build recipes for several open source components.

The repository is intentionally generic:

- It is not tied to any product, vendor, distro, or downstream system.
- It supports multiple packages through small declarative manifests.
- It separates package configuration from build and release logic.
- It only runs manually through `workflow_dispatch`.
- It starts with `linux/amd64`, but the manifest format already leaves room for more targets later.

## What this repo does

At a high level, the repository works like this:

1. You describe a package in `packages/<name>.toml`.
2. The workflow checks out the upstream source at a chosen ref, tag, or commit.
3. It installs the declared build dependencies.
4. It runs the package build commands.
5. It collects the declared output files.
6. It creates a versioned archive and a SHA256 checksum.
7. It can optionally create or update a GitHub Release and upload those files.

That makes the repo useful as a small build and publication system for upstream projects that you want to package yourself.

## Repository layout

```text
.
|-- README.md
|-- packages/
|   |-- gvmd.toml
|   |-- pg-gvm-pg17.toml
|   `-- openvas-scanner.toml
|-- scripts/
|   |-- build_package.sh
|   |-- install_build_deps.sh
|   |-- package_artifacts.sh
|   `-- resolve_package.py
`-- .github/
    `-- workflows/
        `-- build-package.yml
```

## When to use this repository

Use this repository when you want to maintain your own repeatable builds of upstream open source software and publish those builds in a consistent way.

Typical split:

- Some upstream components already publish binaries you trust. Those do not need to live here.
- Some upstream components only publish source, or their published binaries are not what you want to consume. Those are good candidates for this repo.

## Package manifest format

Each package lives in `packages/<package>.toml`.

Example:

```toml
schema_version = 1
id = "openvas-scanner"
name = "OpenVAS Scanner"
description = "Example package built from upstream source."

[upstream]
repo = "https://github.com/greenbone/openvas-scanner.git"
ref = "v23.41.2"
version = "v23.41.2"

[build]
system = "cmake"
subdir = "."
dependencies = ["cmake", "build-essential", "pkg-config"]
commands = [
  "cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local",
  "cmake --build build --parallel \"${BUILD_JOBS}\"",
]

[release]
tag_template = "{package}/{version}-{revision}"
name_template = "{name} {version} ({revision})"
archive_template = "{package}-{version}-{revision}-{os}-{arch}"
notes = """
Internal rebuild of upstream source.
"""

[[targets]]
os = "linux"
arch = "amd64"
archive = "tar.gz"
output_files = [
  "build/openvas",
]
```

Supported top-level fields:

- `schema_version`: Manifest schema version. Start with `1`.
- `id`: Stable package identifier used in workflow input and release tags.
- `name`: Human-readable display name.
- `description`: Short summary.

Supported sections:

- `[upstream]`
  - `repo`: Upstream git repository URL.
  - `ref`: Default upstream ref, tag, or commit to build.
  - `version`: Default release-facing upstream version label. Usually the same as `ref`.
- `[build]`
  - `system`: `cmake`, `cargo`, `make`, or `custom`.
  - `subdir`: Optional working directory inside the checked-out repo.
  - `env`: Optional key/value environment variables exported before the build commands run.
  - `dependency_setup_commands`: Optional shell commands run before dependency installation. Useful when a package needs an extra apt repository or other runner preparation.
  - `dependencies`: System packages required on Debian/Ubuntu runners. Self-hosted runners can preinstall them instead.
  - `commands`: Optional explicit build commands. If omitted, the scripts use a simple default per build system.
- `[release]`
  - `tag_template`: Release tag pattern. Defaults to `{package}/{version}-{revision}`.
  - `name_template`: Release title pattern.
  - `archive_template`: Artifact base name pattern.
  - `notes`: Optional release notes prefix.
- `[[targets]]`
  - `os`: Target OS, currently validated against `linux`.
  - `arch`: Target architecture, initially `amd64`.
  - `archive`: `tar.gz` or `tar.zst`.
  - `output_files`: Files to include in the archive, relative to the upstream repository root after the build completes.

## Versioning and rebuilds

The repository distinguishes between:

- Upstream version: for example `v1.2.3`
- Internal rebuild revision: for example `r1`, `r2`, `r3`

The workflow accepts revision inputs in these forms:

- `1`
- `r1`
- `-r1`
- `.1`

They are normalized to `r1` for release tags and artifact names.

Release tag format:

```text
<package>/<upstream-version>-r<revision>
```

Examples:

- `openvas-scanner/v23.41.2-r1`
- `openvas-scanner/v23.41.2-r2`

This keeps upstream provenance and internal rebuild history separate.

## Manual workflow

The repository only defines manual workflows.

There are no triggers for:

- `push`
- `pull_request`
- git tags

The main workflow is `.github/workflows/build-package.yml`.

Inputs:

- `package`: Manifest id, for example `openvas-scanner`
- `upstream_ref`: Optional override for the git ref/tag/commit
- `release_version`: Optional override for the release-facing version label
- `revision`: Internal rebuild revision, default `1`
- `target_os`: Default `linux`
- `target_arch`: Default `amd64`
- `archive_format`: `tar.gz` or `tar.zst`
- `runner`: `ubuntu-latest` or `self-hosted`
- `publish`: If `true`, create or update a GitHub Release and upload assets
- `upload_artifact`: If `true`, upload the packaged files as workflow artifacts

The default operating model is explicit:

- choose a package
- choose the upstream ref and visible version
- choose the internal rebuild revision
- decide whether the run should only build or also publish

## How to add a new package

1. Copy an existing manifest in `packages/`, for example `packages/openvas-scanner.toml`, to `packages/<your-package>.toml`.
2. Fill in the upstream repository and default ref.
3. Set the build system and either:
   - provide explicit build commands, or
   - rely on the default commands for `cmake`, `cargo`, or `make`.
   - add `build.env` entries if the upstream project needs variables such as `PKG_CONFIG_PATH`.
4. List every produced file you want in the final archive under `targets[].output_files`.
5. Trigger the manual workflow with `publish=false` first.
6. Once the archive contents look correct, rerun with `publish=true`.

## How to run a manual build

From GitHub Actions:

1. Open the `Build Package` workflow.
2. Click `Run workflow`.
3. Enter the package id.
4. Optionally override the upstream ref and release version.
5. Set the internal rebuild revision.
6. Keep `publish=false` for a dry run or enable `publish=true` to push assets into a GitHub Release.

From a local or remote checkout with `act`:

```bash
, act workflow_dispatch \
  -W .github/workflows/build-package.yml \
  --input package=openvas-scanner \
  --input upstream_ref=v23.41.2 \
  --input release_version=v23.41.2 \
  --input revision=1 \
  --input target_os=linux \
  --input target_arch=amd64 \
  --input archive_format=tar.gz \
  --input runner=ubuntu-latest \
  --input publish=false \
  --input upload_artifact=false
```

If you want to simulate release publishing, pass a token:

```bash
, act workflow_dispatch \
  -W .github/workflows/build-package.yml \
  --input package=openvas-scanner \
  --input upstream_ref=v23.41.2 \
  --input release_version=v23.41.2 \
  --input revision=1 \
  --input target_os=linux \
  --input target_arch=amd64 \
  --input archive_format=tar.gz \
  --input runner=ubuntu-latest \
  --input publish=true \
  --input upload_artifact=false \
  -s GITHUB_TOKEN=ghp_your_token
```

For projects that use out-of-tree CMake builds, set `build.subdir = "build"` and define commands such as:

```toml
[build]
system = "cmake"
subdir = "build"

[build.env]
PKG_CONFIG_PATH = "/opt/vendor/lib/pkgconfig"

commands = [
  "cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local ..",
  "make -j\"${BUILD_JOBS}\"",
]
```

## How publishing works

When `publish=true`, the workflow:

1. Resolves the manifest and version metadata.
2. Builds the package from the upstream source ref.
3. Creates `tar.gz` or `tar.zst`.
4. Generates `SHA256SUMS`.
5. Creates or updates the GitHub Release identified by the computed tag.
6. Uploads the archive and checksum file as release assets.

If the release already exists, assets are overwritten with the new internal rebuild output.

## Artifact naming

Archives use this pattern by default:

```text
<package>-<version>-<revision>-<os>-<arch>.<archive-ext>
```

Examples:

- `openvas-scanner-v23.41.2-r1-linux-amd64.tar.gz`
- `openvas-scanner-v23.41.2-r2-linux-amd64.tar.zst`

Checksum file naming:

```text
<archive-basename>.sha256
```

## Using the published artifacts

The published release files are intended to be simple, versioned build outputs:

- download the archive for the release tag you want
- download the matching `.sha256` file
- verify the checksum
- unpack or mirror the artifact wherever you need it

Nothing in the repository assumes a specific downstream consumer. The outputs are just versioned archives plus checksums.

## Runner strategy

The workflow is written to work on:

- GitHub-hosted runners, using `ubuntu-latest`
- self-hosted runners, as long as they provide the required toolchain and network access

The scripts try to install Debian/Ubuntu build dependencies when `apt-get` is available. On self-hosted runners, you can either:

- preinstall dependencies, or
- extend `scripts/install_build_deps.sh` for your own package manager

## Example package included

The repository currently includes three real examples:

- `packages/gvmd.toml`
- `packages/pg-gvm-pg17.toml`
- `packages/openvas-scanner.toml`

`gvmd.toml` uses:

- upstream repo: `https://github.com/greenbone/gvmd.git`
- example ref: `v22.7.0`
- build system: `cmake`
- packaged output: installed `gvmd` binary, runtime data under `share/gvm/gvmd`, configs, and selected helpers

`openvas-scanner.toml` uses:

- upstream repo: `https://github.com/greenbone/openvas-scanner.git`
- example ref: `v23.41.2`
- build system: `cmake`
- packaged output: installed `openvas` binary plus selected installed files

`pg-gvm-pg17.toml` uses:

- upstream repo: `https://github.com/greenbone/pg-gvm.git`
- example ref: `v22.6.15`
- build system: `cmake`
- dependency setup: adds the PostgreSQL apt repository so the runner can install PostgreSQL 17 development headers
- packaged output: the `pg-gvm` extension library and SQL/control files for PostgreSQL 17
