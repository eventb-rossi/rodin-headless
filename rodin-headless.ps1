#!/usr/bin/env pwsh
# Container-only wrapper around the rodin-headless toolchain for Windows.
#
# The rodin-headless engine is a Unix shell toolchain, so on Windows it runs
# through the prebuilt Docker image (linux/amd64) under Docker Desktop or
# Podman Desktop. This mirrors the container path of the rodin-headless bash
# wrapper: it mounts the current directory at /models and forwards the command
# and arguments to the image's entrypoint. The Unix shell scripts are not
# needed here — the engine is baked into the image. (Rodin and ProB themselves
# do ship native Windows builds, but this headless toolchain does not yet drive
# them natively on Windows.)
#
# Usage:   rodin-headless [command] [args...]   (see: rodin-headless help)
# Version: rodin-headless --version

$ErrorActionPreference = 'Stop'

$Image = if ($env:RODIN_IMAGE) { $env:RODIN_IMAGE } else { 'ghcr.io/eventb-rossi/rodin-headless:latest' }

function Show-Usage {
    @'
Usage: rodin-headless <command> [args...]

Commands:
  build [zips...]                Build Event-B models with Rodin (default)
  check [zips...]                Build + model-check with ProB (1000 states)
  prove [zips...]                Build + CBC invariant checking with ProB
  validate [zips...]             Build + full ProB validation (invariants + deadlock + assertions)
  autoprove [zips...]            Build + auto-prove POs with SMT/Atelier B tactics
  probcli [args...]              Run probcli directly
  help                           Show this help

Options (anywhere after the command word):
  --strict                       Exit non-zero when any component fails Rodin's
                                 static check or was never checked

Environment:
  RODIN_IMAGE                    Container image (default ghcr.io/eventb-rossi/rodin-headless:latest)
  RODIN_RUNTIME                  Container engine: docker (default) or podman
  RODIN_BUILD_TIMEOUT            Rodin build timeout (default 60m; off disables)
  RODIN_BUILD_TIMEOUT_KILL_AFTER Grace period after the timeout (default 30s)

On Windows the headless toolchain runs via the Docker image (its engine is a Unix
shell toolchain). Docker Desktop on the WSL2 backend shares the current drive
automatically; on the legacy Hyper-V backend, enable file sharing for the
drive in Docker Desktop settings.
'@
}

# help and --version are offline and must not require a container engine.
$first = if ($args.Count -gt 0) { $args[0] } else { '' }
switch ($first) {
    { $_ -in @('help', '--help', '-h', '/?') } { Show-Usage; exit 0 }
    { $_ -in @('--version', '-V') } {
        $versionFile = Join-Path $PSScriptRoot 'VERSION'
        $version = if (Test-Path -LiteralPath $versionFile) {
            (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim()
        } else { 'unknown' }
        "rodin-headless $version"
        exit 0
    }
}

# Container engine: RODIN_RUNTIME if set (docker|podman), else docker.
$runtime = if ($env:RODIN_RUNTIME) { $env:RODIN_RUNTIME } else { 'docker' }
if ($runtime -notin @('docker', 'podman')) {
    Write-Error "RODIN_RUNTIME must be 'docker' or 'podman' on Windows (got '$runtime')"
    exit 1
}
if (-not (Get-Command $runtime -ErrorAction SilentlyContinue)) {
    Write-Error "$runtime is required on Windows but was not found on PATH. Install Docker Desktop (or Podman Desktop)."
    exit 1
}

# The image is linux/amd64-only; force the platform on ARM64 hosts so it runs
# under emulation instead of failing to find an arm64 variant.
$platformArgs = @()
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
    $platformArgs = @('--platform', 'linux/amd64')
}

# Mount the current directory at /models. Docker Desktop accepts native
# Windows paths, drive-letter colon and all.
$mount = "$($PWD.Path):/models"

& $runtime run --rm @platformArgs `
    -e RODIN_BUILD_TIMEOUT `
    -e RODIN_BUILD_TIMEOUT_KILL_AFTER `
    -v $mount `
    $Image @args

exit $LASTEXITCODE
