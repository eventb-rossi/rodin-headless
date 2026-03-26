# rodin-docker

Docker image for headless [Rodin](https://wiki.event-b.org/index.php/Main_Page) Event-B model building, validation, and proving. Feed it `.zip` archives containing Event-B models and get back static-checked artifacts (`.bcm`/`.bcc`), model checking results, and proof obligation discharge reports.

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
| `check [zips...]` | Build + model-check with ProB (1000 states) |
| `prove [zips...]` | Build + CBC invariant checking with ProB |
| `validate [zips...]` | Build + full ProB validation (invariants + deadlock + assertions) |
| `autoprove [zips...]` | Build + auto-prove POs with SMT/Atelier B tactics |
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

### Validate with ProB

```bash
# Model check (bounded state space exploration, 1000 states)
docker run --rm -v "$(pwd):/models" rodin-headless check model.zip

# Constraint-based invariant proving (tests inductiveness)
docker run --rm -v "$(pwd):/models" rodin-headless prove model.zip

# Full validation (invariants + deadlock + assertions)
docker run --rm -v "$(pwd):/models" rodin-headless validate model.zip

# Custom probcli invocation
docker run --rm -v "$(pwd):/models" rodin-headless probcli model.eventb -mc 5000 -nodead
```

### Auto-prove proof obligations

```bash
# Discharge POs using SMT solvers (Z3, CVC5, veriT) and Atelier B provers (PP, ML)
docker run --rm -v "$(pwd):/models" rodin-headless autoprove model.zip
```

### SELinux / Podman

On Fedora, RHEL, or other SELinux-enforcing systems, add `:Z` to the volume mount:

```bash
docker run --rm -v "$(pwd):/models:Z" rodin-headless model.zip
```

### Standalone (without Docker)

The script can also run directly on a host with Rodin and Java 21+ installed:

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

## What It Does

1. Extracts `.zip` archives into a temporary Rodin workspace
2. Generates `.project` files where missing
3. Compiles and installs a temporary OSGi plugin that imports projects and triggers a full workspace build
4. Runs Rodin headlessly via the Eclipse Equinox launcher
5. Copies all generated/updated files (`.bcm`, `.bcc`, `.bpo`, `.bps`, `.bpr`) back into the original archives
6. Optionally runs ProB validation or Rodin auto-provers (depending on command)

## Image Details

| Component | Version |
|-----------|---------|
| Base image | `eclipse-temurin:21-jdk-noble` |
| Rodin | auto-detected latest stable (currently 3.9) |
| ProB CLI | auto-detected latest stable |
| ProB Rodin plugin | 3.2.1 (core, disprover, symbolic) |
| SMT Solvers plugin | 1.5.0 (Z3, CVC5, veriT, CVC3, CVC4) |
| Atelier B provers | 2.4.1 (PP, ML) |
| Image size | ~1.1 GB |

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
./rodin-version.sh latest-rc    # latest RC
./rodin-version.sh 3.8          # specific version
```

## Model Archive Format

Input `.zip` files should contain an Event-B project — `.bum` (machine) and/or `.buc` (context) files, optionally with a `.project` descriptor. Archives can have a single top-level directory or be flat.

The script resolves the project name using (in priority order):
1. `org.eventb.core.source` references in existing `.bcm` files
2. `<name>` element in `.project`
3. Top-level directory name or zip filename

## License

TBD
