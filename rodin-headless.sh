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
# Usage: ./rodin-headless.sh [--mode MODE] [--strict] [<rodin-dir> <models-dir>] [model1.zip ...]
#   If no specific models are listed, all .zip files in models-dir are processed.
#   Paths can also be set via RODIN_DIR and MODELS_DIR environment variables.
#   RODIN_BUILD_TIMEOUT defaults to 60m; set to off to disable.
#   MODE: build (default), check, prove, validate, autoprove
#   --strict: exit non-zero when any component fails the static check
#
# Examples:
#   ./rodin-headless.sh /home/work/bin/rodin . evbt_bridge.zip evbt_elevator.zip
#   RODIN_DIR=/opt/rodin MODELS_DIR=/models ./rodin-headless.sh model.zip
#   docker run --rm -v "$(pwd):/models" rodin-headless model.zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared shell helpers used by the script and regression tests.
. "$SCRIPT_DIR/rodin-headless-lib.sh"

# Parse --mode/--strict flags; they may appear anywhere among the
# positional arguments, and an unknown option fails fast instead of
# falling through to basename as a bogus archive name.
BUILD_MODE="build"
STRICT_MODE=false
POSITIONAL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)   BUILD_MODE="${2:-build}"; shift 2 ;;
        --strict) STRICT_MODE=true; shift ;;
        --*)
            echo "ERROR: unknown option '$1'" >&2
            exit 1
            ;;
        *)        POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done
set -- ${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}

# Auto-start virtual framebuffer if no display is available (e.g., Docker)
if [ -z "${DISPLAY:-}" ] && command -v Xvfb >/dev/null 2>&1; then
    export DISPLAY=:99
    Xvfb "$DISPLAY" -screen 0 1024x768x24 -nolisten tcp &
    XVFB_PID=$!
    sleep 1
fi

# Registered before any validation exit so an early failure still kills
# the Xvfb we just started; workspace/lock state is guarded because it
# is only created further down.
WORKSPACE=""
PLUGIN_DIR=""
cleanup() {
    # rm -f treats empty operands as already-removed, so the not-yet-set
    # case needs no guard.
    rm -rf "$WORKSPACE" "$PLUGIN_DIR"
    if [ -n "$RODIN_LOCK_KIND" ]; then
        rm -f "$RODIN_PLUGINS/$BUNDLE_JAR_NAME"
        if [ -f "$BUNDLES_INFO" ]; then
            remove_exact_line "$BUNDLES_INFO" "$BUNDLE_INFO_LINE"
        fi
        release_rodin_lock
    fi
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

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
    echo "Usage: $0 [--mode MODE] [--strict] [<rodin-dir> <models-dir>] [model1.zip ...]" >&2
    echo "  Or set RODIN_DIR and MODELS_DIR environment variables." >&2
    exit 1
fi

# The directory with the Eclipse layout: RODIN_DIR itself on Linux,
# Contents/Eclipse inside the macOS app bundle.
RODIN_HOME="$(resolve_rodin_home_or_root "$RODIN_DIR")"

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
# ${arr[@]+...} keeps empty-array expansions alive under bash 3.2's
# set -u (stock macOS), where a bare "${arr[@]}" is fatal.
for zip in ${SELECTED_ZIPS[@]+"${SELECTED_ZIPS[@]}"}; do
    zip=$(basename "$zip")
    if [ -f "$MODELS_DIR/$zip" ]; then
        ZIPS+=("$zip")
    else
        MISSING_ZIPS+=("$zip")
    fi
done

for zip in ${MISSING_ZIPS[@]+"${MISSING_ZIPS[@]}"}; do
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

RODIN_PLUGINS="$RODIN_HOME/plugins"

# The builder plugin compiles against de.prob.core in every mode; fail
# early with a hint instead of dying later in the classpath setup when
# pointed at a bare Rodin install. The resolved directory is reused for
# the compile classpath in step 2.
PROB_CORE_DIR="$(find_prob_plugin "$RODIN_DIR")"
if [ -z "$PROB_CORE_DIR" ]; then
    echo "ERROR: ProB Rodin plugin not installed in $RODIN_DIR" >&2
    echo "Run ./rodin-install.sh to install it" >&2
    exit 1
fi

# Fail in seconds instead of hanging for the whole build timeout: the
# SWT launch in step 3 blocks on WindowServer when macOS has no
# logged-in graphical session (ssh, CI, cron).
if ! darwin_gui_session_ok; then
    echo "ERROR: native Rodin on macOS needs a logged-in graphical (Aqua) session" >&2
    echo "Run from a desktop session, run via the ./rodin wrapper (it falls back to a container), or set RODIN_SKIP_GUI_CHECK=1 to try anyway" >&2
    exit 1
fi

WORKSPACE=$(mktemp -d)
PLUGIN_DIR=$(mktemp -d)
BUNDLES_INFO="$RODIN_HOME/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
LOCK_FILE="$RODIN_HOME/.rodinbuilder.lock"
RUN_ID="$(basename "$PLUGIN_DIR" | tr -cd '[:alnum:]')"
BUNDLE_VERSION="1.0.0"
BUNDLE_SYMBOLIC_NAME="rodinbuilder.$RUN_ID"
BUNDLE_JAR_NAME="rodinbuilder_${RUN_ID}.jar"
BUNDLE_INFO_LINE="$BUNDLE_SYMBOLIC_NAME,$BUNDLE_VERSION,plugins/$BUNDLE_JAR_NAME,4,false"
APPLICATION_ID="$BUNDLE_SYMBOLIC_NAME.headlessBuilder"
RODIN_BUILD_TIMEOUT="${RODIN_BUILD_TIMEOUT:-60m}"
RODIN_BUILD_TIMEOUT_KILL_AFTER="${RODIN_BUILD_TIMEOUT_KILL_AFTER:-30s}"
# Workspace project name per archive, index-parallel to ZIPS — bash 3.2
# (stock macOS) has no associative arrays.
ZIP_PROJECTS=()

echo "Workspace: $WORKSPACE"
echo "Processing ${#ZIPS[@]} archives"
echo

# --- Step 1: Extract archives into workspace ---
echo "=== Step 1: Extracting archives ==="
for zip_index in "${!ZIPS[@]}"; do
    zip="${ZIPS[$zip_index]}"
    m="${zip%.zip}"

    tmpdir=$(mktemp -d)
    unzip -q "$MODELS_DIR/$zip" -d "$tmpdir"

    # One walk serves both the root count and the source directory.
    # Extracting the first *project* root (same sort order step 4's
    # repackaging uses) keeps extraction and write-back pointed at the
    # same directory, and skips non-project clutter (docs/, media/)
    # that a first-top-level-dir heuristic could pick up instead of
    # the model. BSD wc pads the count with leading spaces.
    archive_roots=$(find_archive_project_roots "$tmpdir")
    if [ -n "$archive_roots" ]; then
        project_roots=$(printf '%s\n' "$archive_roots" | wc -l | tr -d ' ')
        srcdir=$(printf '%s\n' "$archive_roots" | head -1)
    else
        # No Event-B sources or .project anywhere: keep the legacy
        # top-level-directory fallback so the failure surfaces later
        # with a project name attached.
        project_roots=0
        srcdir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)
        [ -n "$srcdir" ] || srcdir="$tmpdir"
    fi

    # Determine project name for workspace directory.
    # Priority: 1) existing .bcm source refs  2) .project <name>  3) subdir/zip name
    projname=""
    for bcm_file in "$srcdir"/*.bcm; do
        [ -f "$bcm_file" ] || continue
        projname=$(sed -n 's|.*org.eventb.core.source="/\([^/"]*\).*|\1|p' "$bcm_file" | head -1 || true)
        [ -n "$projname" ] && break
    done
    if [ -z "$projname" ] && [ -f "$srcdir/.project" ]; then
        projname=$(sed -n 's|.*<name>\([^<]*\)</name>.*|\1|p' "$srcdir/.project" | head -1 || true)
    fi
    # Fall back if empty or would collide with an existing workspace project
    if [ -z "$projname" ] || [ -d "$WORKSPACE/$projname" ]; then
        if [ "$srcdir" != "$tmpdir" ]; then
            projname=$(basename "$srcdir")
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
    ZIP_PROJECTS[$zip_index]="$projname"
    echo "  $m → $projname"
    # One project per archive: extraction keeps a single project root
    # and repackaging writes a single one back, so extra projects would
    # be dropped silently without this notice. Strict mode promises a
    # non-zero exit for anything that never got checked — dropped
    # projects included — so there it is fatal.
    if [ "$project_roots" -gt 1 ]; then
        if [ "$STRICT_MODE" = true ]; then
            echo "ERROR: $zip contains $project_roots project roots; strict mode refuses to drop the extras (one project per archive)" >&2
            exit 1
        fi
        echo "  WARNING: $zip contains $project_roots project roots; only '$projname' is built and repackaged" >&2
    fi
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
import de.prob.prolog.output.StructuredPrologOutput;
import de.prob.prolog.term.PrologTerm;
import org.eventb.core.seqprover.IConfidence;
import org.eventb.core.ast.Formula;
import org.eventb.core.ast.FormulaFactory;
import org.eventb.core.ast.Predicate;
import de.prob.sap.util.FormulaUtils;
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

        // Launch success says nothing about the model; surface the
        // static checker's per-component verdict, and in strict mode
        // fail before autoprove/ProB can pile errors on a model that
        // never statically checked.
        boolean scAccurate = reportStaticCheck(root);
        if (Boolean.getBoolean("rodinbuilder.strict") && !scAccurate) {
            System.out.println("\nStrict mode: failing due to static check errors.");
            return Integer.valueOf(1);
        }

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

    // The static checker records where it dropped or changed elements
    // as org.eventb.core.accurate="false" attributes in the .bcc/.bcm
    // output — the verdict consumers otherwise have to grep out of the
    // repackaged archives.
    private boolean reportStaticCheck(IWorkspaceRoot root) throws Exception {
        boolean allAccurate = true;
        System.out.println("\n=== Static check results ===");
        for (IProject project : root.getProjects()) {
            if (!project.isOpen()) continue;
            IRodinProject rp = RodinCore.valueOf(project);
            for (IMachineRoot m : rp.getRootElementsOfType(IMachineRoot.ELEMENT_TYPE))
                allAccurate &= reportComponent(m.getComponentName(), m.getSCMachineRoot());
            for (IContextRoot c : rp.getRootElementsOfType(IContextRoot.ELEMENT_TYPE))
                allAccurate &= reportComponent(c.getComponentName(), c.getSCContextRoot());
        }
        System.out.println(allAccurate
            ? "Static check: ALL COMPONENTS ACCURATE"
            : "Static check: ERRORS DETECTED");
        return allAccurate;
    }

    // Accuracy is recorded per element, not just on the file root: a
    // filtered action marks its event inaccurate while the root stays
    // accurate. Walk the whole tree and name the first lossy element.
    private String findInaccurate(IRodinElement element) throws Exception {
        if (element instanceof IAccuracyElement
                && !((IAccuracyElement) element).isAccurate()) {
            return element instanceof ILabeledElement
                ? ((ILabeledElement) element).getLabel()
                : element.getElementName();
        }
        if (element instanceof IParent) {
            for (IRodinElement child : ((IParent) element).getChildren()) {
                String hit = findInaccurate(child);
                if (hit != null) return hit;
            }
        }
        return null;
    }

    // A missing SC root counts as a failure: the component was never
    // successfully checked, which is exactly what strict mode is for.
    private boolean reportComponent(String name, IInternalElement scRoot) {
        try {
            if (!scRoot.exists()) {
                System.out.println("  " + name + ": NOT CHECKED (no static-check output)");
                return false;
            }
            String inaccurate = findInaccurate(scRoot);
            if (inaccurate == null) {
                System.out.println("  " + name + ": OK");
                return true;
            }
            System.out.println("  " + name + ": STATIC CHECK ERRORS (at " + inaccurate + ")");
            return false;
        } catch (Exception e) {
            System.err.println("  " + name + ": accuracy unreadable: " + e.getMessage());
            return false;
        }
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
                            new ConstraintBasedDeadlockCheckCommand(makeTruePredicateTerm());
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

    private PrologTerm makeTruePredicateTerm() {
        FormulaFactory factory = FormulaFactory.getDefault();
        Predicate predicate = factory.makeLiteralPredicate(Formula.BTRUE, null);
        StructuredPrologOutput output = new StructuredPrologOutput();
        FormulaUtils.printPredicate(predicate, output);
        return output.getFinishedTerm();
    }

    @Override
    public void stop() {}
}
JAVA

cat > "$PLUGIN_DIR/plugin.xml" << XML
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

cat > "$PLUGIN_DIR/META-INF/MANIFEST.MF" << MF
Manifest-Version: 1.0
Bundle-ManifestVersion: 2
Bundle-Name: Rodin Headless Builder
Bundle-SymbolicName: $BUNDLE_SYMBOLIC_NAME;singleton:=true
Bundle-Version: $BUNDLE_VERSION
Require-Bundle: org.eclipse.core.resources,
 org.eclipse.core.runtime,
 org.eclipse.equinox.app,
 de.prob.core,
 org.eventb.core,
 org.eventb.core.ast,
 org.eventb.core.seqprover,
 org.rodinp.core
Bundle-RequiredExecutionEnvironment: JavaSE-21
MF

# Compile against Rodin's Eclipse and plugin JARs
CP=$(resolve_latest_jar "$RODIN_PLUGINS" org.eclipse.core.resources)
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eclipse.core.runtime)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eclipse.equinox.app)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eclipse.equinox.common)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eclipse.core.jobs)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eclipse.osgi)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eventb.core)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eventb.core.ast)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.rodinp.core)"
CP="$CP:$(resolve_latest_jar "$RODIN_PLUGINS" org.eventb.core.seqprover)"
CP="$CP:$PROB_CORE_DIR"
# de.prob.core has nested JARs in lib/dependencies/
for jar in "$PROB_CORE_DIR"/lib/dependencies/*.jar; do
    [ -f "$jar" ] && CP="$CP:$jar"
done

javac -cp "$CP" "$PLUGIN_DIR/rodinbuilder/HeadlessBuilder.java"
jar cfm "$PLUGIN_DIR/$BUNDLE_JAR_NAME" "$PLUGIN_DIR/META-INF/MANIFEST.MF" \
    -C "$PLUGIN_DIR" plugin.xml \
    -C "$PLUGIN_DIR" rodinbuilder/HeadlessBuilder.class

echo "  Plugin built: $PLUGIN_DIR/$BUNDLE_JAR_NAME"
echo

# --- Step 3: Install plugin and run Rodin headless builder ---
echo "=== Step 3: Running Rodin headless builder ==="
# Install plugin to plugins/ directory and register in bundles.info.
# Hold the lock until cleanup so concurrent standalone runs cannot clobber the bundle.
acquire_rodin_lock "$LOCK_FILE"
cp "$PLUGIN_DIR/$BUNDLE_JAR_NAME" "$RODIN_PLUGINS/$BUNDLE_JAR_NAME"
if [ -f "$BUNDLES_INFO" ]; then
    echo "$BUNDLE_INFO_LINE" >> "$BUNDLES_INFO"
fi

# SWT's Cocoa port must run on the JVM's first thread; Linux JVMs
# reject the flag, so it is spliced in on Darwin only.
JAVA_PLATFORM_OPTS=()
if [ "$(host_os)" = Darwin ]; then
    JAVA_PLATFORM_OPTS=(-XstartOnFirstThread)
fi

# Build the Rodin launch command (prefer equinox launcher JAR over native binary)
LAUNCHER_JAR=$(resolve_latest_jar "$RODIN_PLUGINS" org.eclipse.equinox.launcher)
RODIN_VMARGS=()
if [ -n "$LAUNCHER_JAR" ]; then
    RODIN_CMD=(java "-Drodinbuilder.mode=$BUILD_MODE" "-Drodinbuilder.strict=$STRICT_MODE"
        "${JDK_XML_RELAXED_OPTS[@]}"
        ${JAVA_PLATFORM_OPTS[@]+"${JAVA_PLATFORM_OPTS[@]}"}
        -jar "$LAUNCHER_JAR" -install "$RODIN_HOME")
else
    RODIN_CMD=("$(resolve_rodin_launcher "$RODIN_DIR" || printf '%s\n' "$RODIN_DIR/rodin")")
    # The native launcher takes JVM options only after a trailing
    # -vmargs; appendVmargs keeps rodin.ini's own vmargs (heap size)
    # intact instead of replacing them.
    RODIN_VMARGS=(--launcher.appendVmargs -vmargs
        "${JDK_XML_RELAXED_OPTS[@]}"
        "-Drodinbuilder.mode=$BUILD_MODE" "-Drodinbuilder.strict=$STRICT_MODE")
fi

echo "Rodin build timeout: $RODIN_BUILD_TIMEOUT"

LAUNCH_STATUS=0
run_with_filtered_output \
    run_with_optional_timeout "$RODIN_BUILD_TIMEOUT" "$RODIN_BUILD_TIMEOUT_KILL_AFTER" \
    "${RODIN_CMD[@]}" \
    -nosplash -clean \
    -application "$APPLICATION_ID" \
    -data "$WORKSPACE" \
    -consolelog \
    ${RODIN_VMARGS[@]+"${RODIN_VMARGS[@]}"} || LAUNCH_STATUS=$?
echo

case "$LAUNCH_STATUS" in
    124 | 137)
        echo "ERROR: Rodin headless builder timed out after $RODIN_BUILD_TIMEOUT; skipping archive repackaging." >&2
        exit "$LAUNCH_STATUS"
        ;;
    125)
        # The timeout tool itself failed (e.g. unparsable duration) —
        # no build ran, so repackaging would silently report success.
        echo "ERROR: could not enforce RODIN_BUILD_TIMEOUT=$RODIN_BUILD_TIMEOUT; skipping archive repackaging." >&2
        exit "$LAUNCH_STATUS"
        ;;
    130)
        echo "ERROR: Rodin headless builder was interrupted; skipping archive repackaging." >&2
        exit "$LAUNCH_STATUS"
        ;;
esac

# --- Step 4: Check results and repackage ---
echo "=== Step 4: Repackaging archives ==="

for zip_index in "${!ZIPS[@]}"; do
    zip="${ZIPS[$zip_index]}"
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
    if [ -n "${ZIP_PROJECTS[$zip_index]:-}" ]; then
        candidate="$WORKSPACE/${ZIP_PROJECTS[$zip_index]}"
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
if [ "$LAUNCH_STATUS" -ne 0 ]; then
    exit "$LAUNCH_STATUS"
fi

echo "Done."
