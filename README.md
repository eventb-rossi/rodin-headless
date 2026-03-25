# rodin-docker

Docker image for headless [Rodin](https://wiki.event-b.org/index.php/Main_Page) Event-B model building. Feed it `.zip` archives containing Event-B models and get back static-checked artifacts (`.bcm`/`.bcc`).

## Quick Start

```bash
docker build -t rodin-headless .
docker run --rm -v "$(pwd):/models" rodin-headless my-model.zip
```

The built artifacts are written back into the zip in-place.

## Commands

```bash
docker run --rm -v "$(pwd):/models" rodin-headless <command> [args...]
```

| Command | Description |
|---------|-------------|
| `build [zips...]` | Build Event-B models with Rodin (default) |
| `check <file> [opts...]` | Model-check with ProB (`probcli -mc 1000`) |
| `probcli [args...]` | Run probcli directly with arbitrary arguments |
| `help` | Show available commands |

If no command is given, `build` is assumed (backward compatible).

### Build models

```bash
# Build all .zip models in a directory
docker run --rm -v /path/to/models:/models rodin-headless

# Build specific models
docker run --rm -v "$(pwd):/models" rodin-headless build model1.zip model2.zip
```

### Model check with ProB

```bash
# Quick model check (1000 states)
docker run --rm -v "$(pwd):/models" rodin-headless check my-project/M1.bum

# Custom probcli invocation
docker run --rm -v "$(pwd):/models" rodin-headless probcli my-project/M1.bum -mc 5000 -nodead
```

### SELinux / Podman

On Fedora, RHEL, or other SELinux-enforcing systems, add `:Z` to the volume mount:

```bash
docker run --rm -v "$(pwd):/models:Z" rodin-headless model.zip
```

### Standalone (without Docker)

The build script can also run directly on a host with Rodin and Java 21+ installed:

```bash
./rodin-headless-build.sh /path/to/rodin /path/to/models [model1.zip ...]
```

Or via environment variables:

```bash
export RODIN_DIR=/opt/rodin MODELS_DIR=./models
./rodin-headless-build.sh model1.zip
```

## What It Does

1. Extracts `.zip` archives into a temporary Rodin workspace
2. Generates `.project` files where missing
3. Compiles and installs a temporary OSGi plugin that imports projects and triggers a full workspace build
4. Runs Rodin headlessly via the Eclipse Equinox launcher
5. Copies generated `.bcm`/`.bcc` artifacts back into the original archives

## Image Details

| Component | Version |
|-----------|---------|
| Base image | `eclipse-temurin:21-jdk-jammy` |
| Rodin | auto-detected latest stable (currently 3.9) |
| ProB CLI | 1.15.1 |
| ProB Rodin plugin | 3.2.1 (core, disprover, symbolic) |
| Image size | ~900 MB |

### Rodin Version Selection

By default, `docker build` auto-detects the latest stable Rodin version from SourceForge:

```bash
# Latest stable (default)
docker build -t rodin-headless .

# Latest release candidate
docker build --build-arg RODIN_VERSION=latest-rc -t rodin-headless .

# Specific version
docker build --build-arg RODIN_VERSION=3.8 -t rodin-headless .

# Fully pinned (skip auto-detection)
docker build \
  --build-arg RODIN_VERSION=3.9 \
  --build-arg RODIN_TARBALL=rodin-3.9.0.202406100806-9b87fe13d-linux.gtk.x86_64.tar.gz \
  -t rodin-headless .
```

The `rodin-version.sh` helper script can also be used standalone to query available versions:

```bash
./rodin-version.sh              # latest stable
./rodin-version.sh --rc         # latest RC
./rodin-version.sh --version 3.8
```

## ProB

The image includes [ProB](https://prob.hhu.de/) for model checking and animation:

```bash
docker run --rm -v "$(pwd):/models" rodin-headless check my-project/M1.bum
docker run --rm -v "$(pwd):/models" rodin-headless probcli my-project/M1.bum -cbc_deadlock
```

The ProB Rodin plugin (core, disprover, symbolic) is also installed, making ProB available during Rodin workspace builds.

## Model Archive Format

Input `.zip` files should contain an Event-B project — `.bum` (machine) and/or `.buc` (context) files, optionally with a `.project` descriptor. Archives can have a single top-level directory or be flat.

The script resolves the project name using (in priority order):
1. `org.eventb.core.source` references in existing `.bcm` files
2. `<name>` element in `.project`
3. Top-level directory name or zip filename

## License

TBD
