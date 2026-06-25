# rodin-headless

[![CI](https://github.com/eventb-rossi/rodin-headless/actions/workflows/ci.yml/badge.svg)](https://github.com/eventb-rossi/rodin-headless/actions/workflows/ci.yml)

Headless toolchain for building, model-checking, and proving [Rodin](https://wiki.event-b.org/index.php/Main_Page) Event-B models — natively on Linux or macOS, or via Docker. Feed it `.zip` archives containing Event-B models and get back static-checked artifacts (`.bcm`/`.bcc`), model checking results, and proof obligation discharge reports.

## Quick Start

```bash
git clone https://github.com/eventb-rossi/rodin-headless.git
cd rodin-headless

./rodin-headless my-model.zip
```

The `rodin-headless` wrapper picks a runtime automatically: a native Rodin install if one is present, otherwise the Docker image. In container mode it pulls the prebuilt image published to GHCR (`ghcr.io/eventb-rossi/rodin-headless:latest`) on first run, falling back to a local `docker build` when the pull is unavailable (offline). The current directory is mounted and built artifacts are written back into the zip in-place.

## Installation

Prebuilt packages are published for the major package managers; each tracks the
latest `rodin-headless` release.

### Homebrew (macOS / Linux)

```bash
brew tap eventb-rossi/tap
brew install rodin-headless
```

### APT (Ubuntu 26.04 "Resolute" or later)

```bash
curl -fsSL https://eventb-rossi.github.io/apt/KEY.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/eventb.gpg
echo "deb [signed-by=/etc/apt/keyrings/eventb.gpg] https://eventb-rossi.github.io/apt resolute main" \
  | sudo tee /etc/apt/sources.list.d/eventb.list
sudo apt update
sudo apt install rodin-headless
```

### Scoop (Windows)

```powershell
scoop bucket add eventb https://github.com/eventb-rossi/scoop-eventb
scoop install eventb/rodin-headless
```

### Gentoo

```bash
eselect repository eventb-rossi
emaint sync -r eventb-rossi
emerge -av rodin-headless
```

### Fedora (COPR)

```bash
sudo dnf copr enable @eventb-rossi/eventb-copr
sudo dnf install rodin-headless
```

### Native install (Linux x86_64, macOS)

```bash
./rodin-headless-install --check-deps   # report missing system packages
./rodin-headless-install                # install Rodin + ProB + plugins
./rodin-headless my-model.zip              # now runs without Docker
```

The installer downloads Rodin and the ProB CLI, points `rodin.ini` at your JVM, and installs the ProB/SMT/Atelier B Rodin plugins — into `~/.local/share/rodin-headless` by default (override with `--prefix DIR` or `RODIN_PREFIX`). It never uses sudo; system packages (JDK 21+, GTK3, Xvfb, zip/unzip) are reported by `--check-deps` with install hints instead.

On macOS the only prerequisite is a JDK 21+ (e.g. Temurin) — everything else ships with the system, and the engine has a built-in fallback for the GNU `timeout` tool. Apple Silicon needs Rodin 3.10 or later, the first release with arm64 mac builds; until 3.10 final ships, install it with `--rodin-version latest-rc` (3.9 mac builds are x86_64-only and are never selected on arm64).

Native macOS additionally requires a logged-in graphical (Aqua) session — SWT's Cocoa port blocks on WindowServer without one. Over ssh/CI/cron the wrapper detects this and falls back to the container runtime automatically; a forced `RODIN_RUNTIME=native` run fails in seconds with a clear error instead of hanging until the build timeout. Set `RODIN_SKIP_GUI_CHECK=1` to bypass the probe if it ever misdetects your session.

```bash
./rodin-headless-install [--prefix DIR] [--only rodin|prob] [--force]
                   [--rodin-version V] [--rodin-tarball F] [--prob-version V]
                   [--check-deps]
```

Re-running is safe: completed phases are skipped unless `--force` is given.

### Windows

The `rodin-headless` engine is a Unix shell toolchain, so on Windows it runs through
the Docker image rather than natively. A PowerShell wrapper, `rodin-headless.ps1`,
runs it: it mounts the current directory at `/models` and forwards the command to the
prebuilt image, mirroring the container path of the bash wrapper. (Rodin and ProB do
ship native Windows x86_64 builds — packaged as `rodin` and `prob` in the eventb-rossi
Scoop bucket — but this headless toolchain is not yet wired up to drive them natively
on Windows.)

```powershell
rodin-headless build model.zip   # runs ghcr.io/eventb-rossi/rodin-headless via Docker Desktop
rodin-headless --version
rodin-headless help
```

It needs Docker Desktop (or Podman Desktop via `RODIN_RUNTIME=podman`). On the
WSL2 backend the current drive is shared automatically; on the legacy Hyper-V
backend, enable file sharing for the drive in Docker Desktop settings. The same
`RODIN_IMAGE` and `RODIN_BUILD_TIMEOUT` variables apply. The Scoop manifest is
maintained in a separate bucket and fetches this `rodin-headless.ps1`.

### Installing from source (packagers)

For a system-wide install — and as the entry point downstream packaging
recipes (Debian, Fedora/COPR, Gentoo, Homebrew) build on — use the Makefile:

```bash
make install prefix=/usr DESTDIR="$pkgdir"   # stage into a package root
make install prefix=/usr/local               # install directly
make uninstall prefix=/usr/local
```

It follows the GNU directory variables (`prefix`, `bindir`, `libexecdir`,
`datadir`, `mandir`): the `rodin-headless` and `rodin-headless-install`
commands go in `$bindir`, the engine/library/helpers in
`$libexecdir/rodin-headless`, the local-build Docker context in
`$datadir/rodin-headless`, and the man pages in `$mandir/man1`. The bash
scripts have no build step; this only copies files and rewrites the
library-location markers to the install paths.



## Commands

```bash
./rodin-headless <command> [args...]
```

| Command | Description |
|---------|-------------|
| `build [zips...]` | Build Event-B models with Rodin (default) |
| `check [zips...]` | Build + model-check with ProB (1000 states) |
| `prove [zips...]` | Build + CBC invariant checking with ProB |
| `validate [zips...]` | Build + full ProB validation (invariants + deadlock + assertions) |
| `autoprove [zips...]` | Build + auto-prove POs with SMT/Atelier B tactics |
| `probcli [args...]` | Run probcli directly with arbitrary arguments |
| `help` | Show available commands |

If no command is given, `build` is assumed.
`./rodin-headless help` is handled locally and does not require a native install, Docker, podman, or a prebuilt image.

Every model command prints a per-component static-check summary after the build and accepts `--strict` (anywhere after the command word): with it, the run exits non-zero when any component fails Rodin's static check — or was never checked, which includes archives carrying more than one project (the extras would be dropped unchecked, so strict rejects the archive) — instead of the exit code only reflecting whether Rodin launched. Without `--strict` the summary is informational and consumers can keep parsing `org.eventb.core.accurate` from the repackaged `.bcm`/`.bcc` files.

```bash
./rodin-headless build --strict model.zip   # exit 1 if the model does not statically check
```

## Runtime Selection

The wrapper resolves the runtime in this order (`RODIN_RUNTIME=auto`, the default):

1. `RODIN_DIR` pointing at a Rodin install (`rodin.ini` present) → native
2. An `./rodin-headless-install` install under the default prefix → native
3. docker or podman available → container

Force a specific runtime with `RODIN_RUNTIME=native`, `RODIN_RUNTIME=docker`, or `RODIN_RUNTIME=podman`:

```bash
RODIN_RUNTIME=docker ./rodin-headless build model.zip   # skip native detection
RODIN_RUNTIME=native ./rodin-headless check model.zip   # fail if no native install
```

In native mode the wrapper exports `RODIN_DIR`, uses the current directory as the models directory, and puts the sibling `prob/` directory on `PATH` for `probcli`.

### Unattended / batch use

For SSH sessions, CI, cron, and other non-interactive batch runs, the container runtime is the supported path: it brings its own virtual display (Xvfb) and needs no desktop session. Native Linux works unattended too when Xvfb is installed. Native macOS does **not**: SWT's Cocoa port requires a logged-in graphical (Aqua) session, so native runs only work from a real desktop session — see the macOS notes below.

On Apple Silicon this means there is currently no fast unattended path: the container is emulated x86_64 (slow), and the native arm64 build is desktop-session-bound. See [Apple Silicon expectations](#apple-silicon-expectations).

### Build models

```bash
# Build all .zip models in current directory
./rodin-headless

# Build specific models
./rodin-headless build model1.zip model2.zip
```

If no matching archives are found, the wrapper exits non-zero instead of succeeding as a no-op.

Rodin workspace builds have a hard timeout of 60 minutes by default. Override
it with `RODIN_BUILD_TIMEOUT`, or set `RODIN_BUILD_TIMEOUT=off` to disable it.
`RODIN_BUILD_TIMEOUT` and `RODIN_BUILD_TIMEOUT_KILL_AFTER` work in both
runtimes; in Docker mode the wrapper forwards them into the container.

### Validate with ProB

```bash
# Model check (bounded state space exploration, 1000 states)
./rodin-headless check model.zip

# Constraint-based invariant proving (tests inductiveness)
./rodin-headless prove model.zip

# Full validation (invariants + deadlock + assertions)
./rodin-headless validate model.zip

# Custom probcli invocation
./rodin-headless probcli model.eventb -mc 5000 -nodead
```

### Auto-prove proof obligations

```bash
# Discharge POs using SMT solvers (Z3, CVC5, veriT) and Atelier B provers (PP, ML)
./rodin-headless autoprove model.zip
```

### SELinux / Podman

In Docker mode the `rodin-headless` wrapper auto-detects SELinux and applies the `:Z` volume flag. Docker and podman are both supported.

With a rootful engine (the typical Linux Docker daemon) the wrapper runs the container as the invoking user (`--user` with `HOME=/tmp`), so the repackaged zips in the mounted directory come back owned by you instead of root. Rootless podman/docker already map container root to the host user and are left alone.

On macOS, podman only bind-mounts a fixed set of host prefixes into its VM (typically `/Users`, `/private`, `/var/folders` — not `/Volumes`). The wrapper checks this up front and fails with the exact `podman machine set --volume` command to run instead of letting the runtime die with an opaque `statfs ... no such file or directory`. Docker Desktop shares `/Volumes` by default and needs no such step.

### Direct engine invocation

The core engine can be run directly against any Rodin install, without the wrapper:

```bash
./rodin-headless.sh /path/to/rodin /path/to/models [model1.zip ...]

# With a mode
./rodin-headless.sh --mode autoprove /path/to/rodin /path/to/models model.zip
```

Or via environment variables:

```bash
export RODIN_DIR=/opt/rodin MODELS_DIR=./models
./rodin-headless.sh model1.zip
```

The Rodin install must have the ProB plugin (`de.prob.core`) — a stock Rodin download does not; `./rodin-headless-install` sets one up correctly. The installation itself is never written to: each run registers its transient builder plugin in a private temporary Equinox configuration area, so concurrent runs against the same install cannot clobber one another, and even a hard kill leaves the install pristine. (Concurrent runs over the *same* zip still race on repackaging.)

## What It Does

1. Extracts `.zip` archives into a temporary Rodin workspace
2. Generates `.project` files where missing
3. Compiles a temporary OSGi plugin that imports projects and triggers a full workspace build, registered in a throwaway Equinox configuration area — the Rodin install is never modified
4. Runs Rodin headlessly via the Eclipse Equinox launcher
5. Copies all generated/updated files (`.bcm`, `.bcc`, `.bpo`, `.bps`, `.bpr`) back into the original archives
6. Optionally runs ProB validation or Rodin auto-provers (depending on command)

## Docker Image Details

### Prebuilt image

CI publishes the image to the GitHub Container Registry on every push to `main`, on the weekly canary build, and on releases. It is **linux/amd64-only** (Rodin and ProB only ship x86_64 Linux binaries; on arm64 hosts it runs under emulation). Pull and run it directly:

```bash
docker pull ghcr.io/eventb-rossi/rodin-headless:latest
docker run --rm -v "$PWD:/models" ghcr.io/eventb-rossi/rodin-headless build model.zip
```

The `rodin-headless` wrapper uses this image by default in container mode. Two environment variables tune that behavior:

- `RODIN_IMAGE` — override the image ref (default `ghcr.io/eventb-rossi/rodin-headless:latest`), e.g. to pin a datestamped tag or point at a fork.
- `RODIN_BUILD_LOCAL=1` — skip the pull and always build from the local Dockerfile (useful when iterating on it).

Tags: `latest` (rolling — moved by pushes to `main` and the weekly canary), `YYYYMMDD` (weekly canary), and the release version on tagged releases. Releases do **not** move `latest`.

### Building locally

The Dockerfile is a thin layer: it installs the system packages (GTK3/X11, Xvfb, JDK, zip, SMT solvers) and runs the same `rodin-headless-install` with `--prefix /opt`.

| Component | Version |
|-----------|---------|
| Base image | `eclipse-temurin:21-jdk-noble` |
| Rodin | auto-detected latest stable at build time |
| ProB CLI | auto-detected latest stable |
| ProB Rodin plugin | 3.2.1 (core, disprover, symbolic) |
| SMT Solvers plugin | 1.5.0 (Z3, CVC5, veriT, CVC3, CVC4) |
| Atelier B provers | 2.4.1 (PP, ML) |
| Image size | ~1.3 GB |

Images built from `latest` stay auditable after the fact: the requested versions (and any pinned tarball) are recorded as image labels, and the installer writes the **resolved** versions (including the exact Rodin tarball) into a manifest inside the image — labels are advisory, the manifest is canonical. A native install gets the same manifest under its prefix:

```bash
docker image inspect --format '{{json .Config.Labels}}' ghcr.io/eventb-rossi/rodin-headless
docker run --rm --entrypoint cat ghcr.io/eventb-rossi/rodin-headless /opt/.rodin-headless-versions
cat ~/.local/share/rodin-headless/.rodin-headless-versions   # native install
```

### Rodin Version Selection

By default the latest stable Rodin version published on SourceForge is auto-detected. The installer flags and their `docker build` equivalents:

```bash
# Latest stable (default)
./rodin-headless-install
docker build -t rodin-headless .

# Latest release candidate
./rodin-headless-install --rodin-version latest-rc
docker build --build-arg RODIN_VERSION=latest-rc -t rodin-headless .

# Specific version
./rodin-headless-install --rodin-version 3.8
docker build --build-arg RODIN_VERSION=3.8 -t rodin-headless .

# Fully pinned (skip auto-detection)
./rodin-headless-install --rodin-version 3.9 \
    --rodin-tarball rodin-3.9.0.202406100806-9b87fe13d-linux.gtk.x86_64.tar.gz
docker build \
  --build-arg RODIN_VERSION=3.9 \
  --build-arg RODIN_TARBALL=rodin-3.9.0.202406100806-9b87fe13d-linux.gtk.x86_64.tar.gz \
  -t rodin-headless .
```

On macOS, native mode uses the platform Rodin build (an app bundle; the
toolchain finds the Eclipse layout inside it automatically) and the universal
ProB CLI. On Apple Silicon that requires Rodin 3.10+ — see the native install
section above. Without a native install the wrapper falls back to the
container path and builds the image for `linux/amd64`, since the container
unpacks Linux x86_64 binaries that a native `linux/arm64` image could not run:

```bash
docker build --platform linux/amd64 -t rodin-headless .
podman build --platform linux/amd64 -t rodin-headless .
```

The `./rodin-headless` wrapper applies this platform flag automatically when it builds
and runs the image on macOS ARM64.

### Apple Silicon expectations

There is no fast headless path on Apple Silicon today, and it is worth knowing
before burning time on it:

- The container runs Rodin's and ProB's Linux x86_64 binaries under emulation
  (Rosetta/QEMU). It works unattended, but expect builds to be several times
  slower than native.
- The native arm64 build (Rodin 3.10+) is fast, but only runs from a
  logged-in graphical session — it is not usable over SSH or in CI.

This is not fixable in this repo until Rodin ships arm64 Linux builds. If you
need fast unattended runs from a Mac, run the corpus on an x86_64 Linux host
(a future `RODIN_RUNTIME=ssh`-style remote runner may automate that; today it
is a manual step).

The `rodin-version.sh` helper script can also be used standalone to query the highest available stable or RC version:

```bash
./rodin-version.sh              # latest stable
./rodin-version.sh latest-rc    # latest RC
./rodin-version.sh 3.8          # specific version
```

## Model Archive Format

Input `.zip` files should contain an Event-B project — `.bum` (machine) and/or `.buc` (context) files, optionally with a `.project` descriptor. Archives can have a single top-level directory or be flat.

Exactly **one project per archive**: when a zip contains several project roots, only the first is built and written back (a warning is printed, and `--strict` rejects the archive outright). Ship one zip per project instead.

The script resolves the project name using (in priority order):
1. `org.eventb.core.source` references in existing `.bcm` files
2. `<name>` element in `.project`
3. Top-level directory name or zip filename

## License

[MIT](LICENSE)
