#!/usr/bin/env bash
# Build Event-B models using Rodin's headless static checker.
#
# This script:
# 1. Extracts .zip archives into a Rodin workspace directory
# 2. Generates .project files where missing (needed for Rodin to recognize projects)
# 3. Installs a temporary OSGi plugin into Rodin that programmatically imports
#    and builds all projects in the workspace
# 4. Runs Rodin headless with the plugin
# 5. Repackages the archives with the generated .bcm/.bcc artifacts
#
# Prerequisites:
# - Rodin IDE installed (Eclipse-based)
# - Java 21+ (for compiling the OSGi plugin)
#
# Usage: ./rodin-headless.sh [--mode MODE] [<rodin-dir> <models-dir>] [model1.zip ...]
#   If no specific models are listed, all .zip files in models-dir are processed.
#   Paths can also be set via RODIN_DIR and MODELS_DIR environment variables.
#   MODE: build (default), check, prove, validate
#
# Examples:
#   ./rodin-headless.sh /home/work/bin/rodin . evbt_bridge.zip evbt_elevator.zip
#   RODIN_DIR=/opt/rodin MODELS_DIR=/models ./rodin-headless.sh model.zip
#   docker run --rm -v "$(pwd):/models" rodin-headless model.zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared shell helpers used by the script and regression tests.
. "$SCRIPT_DIR/rodin-headless-lib.sh"

# Parse --mode flag
BUILD_MODE="build"
if [ "${1:-}" = "--mode" ]; then
    BUILD_MODE="${2:-build}"
    shift 2
fi

# Auto-start virtual framebuffer if no display is available (e.g., Docker)
if [ -z "${DISPLAY:-}" ] && command -v Xvfb >/dev/null 2>&1; then
    export DISPLAY=:99
    Xvfb "$DISPLAY" -screen 0 1024x768x24 -nolisten tcp &
    XVFB_PID=$!
    sleep 1
fi

# Resolve RODIN_DIR and MODELS_DIR from positional args or environment variables
if [ $# -ge 2 ] && [ -d "${1:-}" ] && [ -d "${2:-}" ]; then
    RODIN_DIR="$1"
    MODELS_DIR="$(cd "$2" && pwd)"
    shift 2
else
    RODIN_DIR="${RODIN_DIR:-}"
    MODELS_DIR="${MODELS_DIR:+$(cd "$MODELS_DIR" && pwd)}"
fi

if [ -z "$RODIN_DIR" ] || [ -z "$MODELS_DIR" ]; then
    echo "Usage: $0 [<rodin-dir> <models-dir>] [model1.zip ...]" >&2
    echo "  Or set RODIN_DIR and MODELS_DIR environment variables." >&2
    exit 1
fi

# Determine which archives to process
if [ $# -gt 0 ]; then
    SELECTED_ZIPS=("$@")
else
    shopt -s nullglob
    SELECTED_ZIPS=("$MODELS_DIR"/*.zip)
    shopt -u nullglob
fi

ZIPS=()
MISSING_ZIPS=()
for zip in "${SELECTED_ZIPS[@]}"; do
    zip=$(basename "$zip")
    if [ -f "$MODELS_DIR/$zip" ]; then
        ZIPS+=("$zip")
    else
        MISSING_ZIPS+=("$zip")
    fi
done

for zip in "${MISSING_ZIPS[@]}"; do
    echo "  SKIP: $zip not found" >&2
done

if [ ${#ZIPS[@]} -eq 0 ]; then
    if [ $# -gt 0 ]; then
        echo "ERROR: None of the requested archives were found in $MODELS_DIR" >&2
    else
        echo "ERROR: No .zip archives found in $MODELS_DIR" >&2
    fi
    exit 1
fi

WORKSPACE=$(mktemp -d)
PLUGIN_DIR=$(mktemp -d)
RODIN_PLUGINS="$RODIN_DIR/plugins"
BUNDLES_INFO="$RODIN_DIR/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
declare -A ZIP_TO_PROJECT  # maps zip basename → workspace project name

cleanup() {
    rm -rf "$WORKSPACE" "$PLUGIN_DIR"
    rm -f "$RODIN_PLUGINS/rodinbuilder_1.0.0.jar"
    [ -f "$BUNDLES_INFO" ] && sed -i '/^rodinbuilder,/d' "$BUNDLES_INFO"
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "Workspace: $WORKSPACE"
echo "Processing ${#ZIPS[@]} archives"
echo

# --- Step 1: Extract archives into workspace ---
echo "=== Step 1: Extracting archives ==="
for zip in "${ZIPS[@]}"; do
    m="${zip%.zip}"

    tmpdir=$(mktemp -d)
    unzip -q "$MODELS_DIR/$zip" -d "$tmpdir"

    subdirs=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -n "$subdirs" ]; then
        srcdir="$subdirs"
    else
        srcdir="$tmpdir"
    fi

    # Determine project name for workspace directory.
    # Priority: 1) existing .bcm source refs  2) .project <name>  3) subdir/zip name
    projname=""
    for bcm_file in "$srcdir"/*.bcm; do
        [ -f "$bcm_file" ] || continue
        projname=$(grep -oP -m1 'org.eventb.core.source="/\K[^/]+' "$bcm_file" || true)
        [ -n "$projname" ] && break
    done
    if [ -z "$projname" ] && [ -f "$srcdir/.project" ]; then
        projname=$(grep -oP -m1 '(?<=<name>)[^<]+' "$srcdir/.project" || true)
    fi
    # Fall back if empty or would collide with an existing workspace project
    if [ -z "$projname" ] || [ -d "$WORKSPACE/$projname" ]; then
        if [ -n "$subdirs" ]; then
            projname=$(basename "$subdirs")
        else
            projname="$m"
        fi
    fi

    mkdir -p "$WORKSPACE/$projname"
    (shopt -s dotglob; mv "$srcdir"/* "$WORKSPACE/$projname/")
    rm -rf "$tmpdir"

    # Generate .project if missing
    projdir="$WORKSPACE/$projname"
    if [ ! -f "$projdir/.project" ]; then
        cat > "$projdir/.project" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<projectDescription>
  <name>$projname</name>
  <comment></comment>
  <projects></projects>
  <buildSpec>
    <buildCommand>
      <name>org.rodinp.core.rodinbuilder</name>
      <arguments></arguments>
    </buildCommand>
  </buildSpec>
  <natures>
    <nature>org.rodinp.core.rodinnature</nature>
  </natures>
</projectDescription>
EOF
    fi
    ZIP_TO_PROJECT["$zip"]="$projname"
    echo "  $m → $projname"
done
echo

# --- Step 2: Build the OSGi headless builder plugin ---
echo "=== Step 2: Building headless builder plugin ==="
mkdir -p "$PLUGIN_DIR/META-INF" "$PLUGIN_DIR/rodinbuilder"

cat > "$PLUGIN_DIR/rodinbuilder/HeadlessBuilder.java" << 'JAVA'
package rodinbuilder;

import org.eclipse.core.resources.*;
import org.eclipse.core.runtime.*;
import org.eclipse.equinox.app.IApplication;
import org.eclipse.equinox.app.IApplicationContext;
import org.rodinp.core.*;
import org.eventb.core.*;
import de.prob.core.Animator;
import de.prob.core.command.*;
import de.prob.prolog.term.CompoundPrologTerm;
import org.eventb.core.seqprover.IConfidence;
import java.io.File;
import java.util.*;

public class HeadlessBuilder implements IApplication {
    @Override
    public Object start(IApplicationContext context) throws Exception {
        IWorkspace workspace = ResourcesPlugin.getWorkspace();
        IWorkspaceRoot root = workspace.getRoot();
        File wsDir = root.getLocation().toFile();

        File[] dirs = wsDir.listFiles();
        if (dirs != null) {
            for (File dir : dirs) {
                if (dir.isDirectory() && new File(dir, ".project").exists()) {
                    String name = dir.getName();
                    IProject project = root.getProject(name);
                    if (!project.exists()) {
                        System.out.println("Importing: " + name);
                        IProjectDescription desc = workspace.newProjectDescription(name);
                        project.create(desc, null);
                        project.open(null);
                    } else if (!project.isOpen()) {
                        System.out.println("Opening: " + name);
                        project.open(null);
                    } else {
                        System.out.println("Already open: " + name);
                    }
                }
            }
        }

        System.out.println("Building workspace...");
        workspace.build(IncrementalProjectBuilder.FULL_BUILD, new NullProgressMonitor());
        System.out.println("Build complete.");

        String mode = System.getProperty("rodinbuilder.mode", "build");
        if ("autoprove".equals(mode)) {
            boolean ok = runAutoProver(root);
            if (!ok) return Integer.valueOf(1);
        } else if (!"build".equals(mode)) {
            boolean ok = runProBValidation(root, mode);
            if (!ok) return Integer.valueOf(1);
        }

        return IApplication.EXIT_OK;
    }

    private boolean runAutoProver(IWorkspaceRoot root) throws Exception {
        boolean allProved = true;

        for (IProject project : root.getProjects()) {
            if (!project.isOpen()) continue;
            IRodinProject rp = RodinCore.valueOf(project);

            // Process both machines and contexts (both can have POs)
            List<IEventBRoot> components = new ArrayList<>();
            for (IMachineRoot m : rp.getRootElementsOfType(IMachineRoot.ELEMENT_TYPE))
                components.add(m);
            for (IContextRoot c : rp.getRootElementsOfType(IContextRoot.ELEMENT_TYPE))
                components.add(c);

            for (IEventBRoot component : components) {
                IPSRoot psRoot = component.getPSRoot();
                if (!psRoot.exists()) continue;
                String name = component.getComponentName();

                try {
                    IPSStatus[] allStatuses = psRoot.getStatuses();
                    Set<IPSStatus> undischarged = new HashSet<>();
                    for (IPSStatus s : allStatuses) {
                        if (s.getConfidence() <= IConfidence.PENDING) {
                            undischarged.add(s);
                        }
                    }

                    System.out.println("\n=== Auto-prove: " + name + " ===");
                    System.out.println("  Total POs: " + allStatuses.length
                        + ", undischarged: " + undischarged.size());

                    if (!undischarged.isEmpty()) {
                        EventBPlugin.runAutoProver(undischarged, new NullProgressMonitor());
                    }

                    // Re-read and report results
                    int discharged = 0;
                    IPSStatus[] updatedStatuses = psRoot.getStatuses();
                    for (IPSStatus s : updatedStatuses) {
                        if (s.getConfidence() > IConfidence.PENDING) discharged++;
                    }
                    System.out.println("  Discharged: " + discharged + "/" + updatedStatuses.length);
                    if (discharged < updatedStatuses.length) allProved = false;
                } catch (Exception e) {
                    System.err.println("  Auto-prove error on " + name + ": " + e.getMessage());
                    allProved = false;
                }
            }
        }

        if (allProved) {
            System.out.println("\nAuto-prover: ALL PROOF OBLIGATIONS DISCHARGED");
        } else {
            System.out.println("\nAuto-prover: SOME PROOF OBLIGATIONS REMAIN");
        }
        return allProved;
    }

    private boolean runProBValidation(IWorkspaceRoot root, String mode) throws Exception {
        Animator animator = Animator.getAnimator();
        boolean allPassed = true;

        for (IProject project : root.getProjects()) {
            if (!project.isOpen()) continue;
            IRodinProject rp = RodinCore.valueOf(project);
            IMachineRoot[] machines = rp.getRootElementsOfType(IMachineRoot.ELEMENT_TYPE);

            for (IMachineRoot machine : machines) {
                String name = machine.getComponentName();
                System.out.println("\n=== ProB: " + name + " ===");

                try {
                    LoadEventBModelCommand.load(animator, machine);
                    StartAnimationCommand.start(animator);

                    if ("check".equals(mode)) {
                        System.out.println("  Model checking (1000 states)...");
                        ModelCheckingCommand.modelcheck(animator, 1000, Collections.emptyList());
                        System.out.println("  Model check complete.");
                    }

                    if ("prove".equals(mode) || "validate".equals(mode)) {
                        System.out.println("  CBC invariant checking...");
                        List<String> events = new ArrayList<>();
                        for (IEvent e : machine.getEvents()) {
                            String label = e.getLabel();
                            if (!"INITIALISATION".equals(label)) events.add(label);
                        }
                        ConstraintBasedInvariantCheckCommand invCmd =
                            new ConstraintBasedInvariantCheckCommand(events);
                        animator.execute(invCmd);
                        System.out.println("  Invariant CBC: " + invCmd.getResult());
                        if (invCmd.getResult() == ConstraintBasedInvariantCheckCommand.ResultType.VIOLATION_FOUND) {
                            allPassed = false;
                        }
                    }

                    if ("validate".equals(mode)) {
                        System.out.println("  CBC deadlock checking...");
                        ConstraintBasedDeadlockCheckCommand dlCmd =
                            new ConstraintBasedDeadlockCheckCommand(new CompoundPrologTerm("truth"));
                        animator.execute(dlCmd);
                        System.out.println("  Deadlock CBC: " + dlCmd.getResult());
                        if (dlCmd.getResult() == ConstraintBasedDeadlockCheckCommand.ResultType.DEADLOCK_FOUND) {
                            allPassed = false;
                        }

                        System.out.println("  CBC assertion checking...");
                        ConstraintBasedAssertionCheckCommand assCmd =
                            new ConstraintBasedAssertionCheckCommand();
                        animator.execute(assCmd);
                        System.out.println("  Assertion CBC: " + assCmd.getResult());
                        if (assCmd.getResult() == ConstraintBasedAssertionCheckCommand.ResultType.COUNTER_EXAMPLE) {
                            allPassed = false;
                        }
                    }
                } catch (Exception e) {
                    System.err.println("  ProB error on " + name + ": " + e.getMessage());
                    allPassed = false;
                }
                // Reset ProB for the next machine
                try { Animator.killAndReload(); } catch (Exception ignored) {}
                animator = Animator.getAnimator();
            }
        }

        if (allPassed) {
            System.out.println("\nProB validation: ALL CHECKS PASSED");
        } else {
            System.out.println("\nProB validation: FAILURES DETECTED");
        }
        return allPassed;
    }

    @Override
    public void stop() {}
}
JAVA

cat > "$PLUGIN_DIR/plugin.xml" << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<?eclipse version="3.4"?>
<plugin>
   <extension id="headlessBuilder" point="org.eclipse.core.runtime.applications">
      <application>
         <run class="rodinbuilder.HeadlessBuilder"/>
      </application>
   </extension>
</plugin>
XML

cat > "$PLUGIN_DIR/META-INF/MANIFEST.MF" << 'MF'
Manifest-Version: 1.0
Bundle-ManifestVersion: 2
Bundle-Name: Rodin Headless Builder
Bundle-SymbolicName: rodinbuilder;singleton:=true
Bundle-Version: 1.0.0
Require-Bundle: org.eclipse.core.resources,
 org.eclipse.core.runtime,
 org.eclipse.equinox.app,
 de.prob.core,
 org.eventb.core,
 org.eventb.core.seqprover,
 org.rodinp.core
Bundle-RequiredExecutionEnvironment: JavaSE-21
MF

# Compile against Rodin's Eclipse and plugin JARs
resolve_jar() { ls "$RODIN_PLUGINS"/$1_*.jar 2>/dev/null | tail -1; }
# de.prob.core is extracted as a directory, not a JAR
resolve_dir() { ls -d "$RODIN_PLUGINS"/$1_*/ 2>/dev/null | tail -1; }

CP=$(resolve_jar org.eclipse.core.resources)
CP="$CP:$(resolve_jar org.eclipse.core.runtime)"
CP="$CP:$(resolve_jar org.eclipse.equinox.app)"
CP="$CP:$(resolve_jar org.eclipse.equinox.common)"
CP="$CP:$(resolve_jar org.eclipse.core.jobs)"
CP="$CP:$(resolve_jar org.eclipse.osgi)"
CP="$CP:$(resolve_jar org.eventb.core)"
CP="$CP:$(resolve_jar org.rodinp.core)"
CP="$CP:$(resolve_jar org.eventb.core.seqprover)"
PROB_CORE_DIR=$(resolve_dir de.prob.core)
CP="$CP:$PROB_CORE_DIR"
# de.prob.core has nested JARs in lib/dependencies/
for jar in "${PROB_CORE_DIR}lib/dependencies"/*.jar; do
    [ -f "$jar" ] && CP="$CP:$jar"
done

javac -cp "$CP" "$PLUGIN_DIR/rodinbuilder/HeadlessBuilder.java"
jar cfm "$PLUGIN_DIR/rodinbuilder.jar" "$PLUGIN_DIR/META-INF/MANIFEST.MF" \
    -C "$PLUGIN_DIR" plugin.xml \
    -C "$PLUGIN_DIR" rodinbuilder/HeadlessBuilder.class

echo "  Plugin built: $PLUGIN_DIR/rodinbuilder.jar"
echo

# --- Step 3: Install plugin and run Rodin headless builder ---
echo "=== Step 3: Running Rodin headless builder ==="
# Install plugin to plugins/ directory and register in bundles.info
cp "$PLUGIN_DIR/rodinbuilder.jar" "$RODIN_PLUGINS/rodinbuilder_1.0.0.jar"
if [ -f "$BUNDLES_INFO" ]; then
    echo "rodinbuilder,1.0.0,plugins/rodinbuilder_1.0.0.jar,4,false" >> "$BUNDLES_INFO"
fi

# Build the Rodin launch command (prefer equinox launcher JAR over native binary)
LAUNCHER_JAR=$(resolve_jar org.eclipse.equinox.launcher)
if [ -n "$LAUNCHER_JAR" ]; then
    RODIN_CMD=(java "-Drodinbuilder.mode=$BUILD_MODE" -jar "$LAUNCHER_JAR" -install "$RODIN_DIR")
else
    RODIN_CMD=("$RODIN_DIR/rodin")
fi

"${RODIN_CMD[@]}" \
    -nosplash -clean \
    -application rodinbuilder.headlessBuilder \
    -data "$WORKSPACE" \
    -consolelog \
    2>&1 | grep -v "^\s*at " | grep -v "^\.\.\." | grep -v "^$" || true
echo

# --- Step 4: Check results and repackage ---
echo "=== Step 4: Repackaging archives ==="

for zip in "${ZIPS[@]}"; do
    m="${zip%.zip}"

    # Extract original zip
    tmpdir=$(mktemp -d)
    unzip -q "$MODELS_DIR/$zip" -d "$tmpdir"

    # Find the project root inside the zip from Event-B sources or .project metadata.
    bumdir=$(find_archive_project_root "$tmpdir")
    if [ -z "$bumdir" ]; then
        rm -rf "$tmpdir"
        continue
    fi

    projdir=""
    if [ -n "${ZIP_TO_PROJECT[$zip]:-}" ]; then
        candidate="$WORKSPACE/${ZIP_TO_PROJECT[$zip]}"
        if [ -d "$candidate" ]; then
            projdir="$candidate"
        fi
    fi

    if [ -n "$projdir" ]; then
        changed=false
        updated=0
        # Copy non-hidden workspace files back to the archive
        # (the glob excludes dotfiles like .project by default)
        for src in "$projdir"/*; do
            [ -f "$src" ] || continue
            fname="${src##*/}"
            dest="$bumdir/$fname"
            if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
                : # identical — keep original file and its timestamp
            else
                cp "$src" "$dest"
                changed=true
                updated=$((updated + 1))
            fi
        done
        if [ "$changed" = true ]; then
            (cd "$tmpdir" && zip -q -r "$MODELS_DIR/$zip" .)
        fi
        echo "  $m: $updated file(s) updated"
    else
        echo "  $m: no matching workspace project found"
    fi

    rm -rf "$tmpdir"
done

echo
echo "Done."
