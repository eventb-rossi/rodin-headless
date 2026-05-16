FROM docker.io/eclipse-temurin:21-jdk-noble

LABEL description="Rodin Event-B IDE headless builder"

# ── System dependencies ─────────────────────────────────────────────
# GTK3 + X11: SWT requires these even headless; xvfb: virtual framebuffer
# z3/cvc5: SMT solvers for theorem proving
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgtk-3-0 \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxtst6 \
        libxi6 \
        libxrandr2 \
        libxcomposite1 \
        libxcursor1 \
        libxdamage1 \
        libxfixes3 \
        libxinerama1 \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libcairo2 \
        libcairo-gobject2 \
        libgdk-pixbuf-2.0-0 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libglib2.0-0 \
        libdbus-1-3 \
        xvfb \
        fonts-dejavu-core \
        zip \
        unzip \
        curl \
        z3 \
        cvc5 \
    && rm -rf /var/lib/apt/lists/*

# ── Download and install Rodin ──────────────────────────────────────
# RODIN_VERSION: "latest" (default), "latest-rc", or a specific version like "3.9"
# RODIN_TARBALL: auto-detected from SourceForge, or override with full filename
ARG RODIN_VERSION=latest
ARG RODIN_TARBALL=

COPY --chmod=755 rodin-version.sh prob-version.sh /tmp/

RUN if [ -z "$RODIN_TARBALL" ]; then \
        rodin_env="$(/tmp/rodin-version.sh "$RODIN_VERSION")" \
        && eval "$rodin_env"; \
    else \
        RODIN_URL="https://sourceforge.net/projects/rodin-b-sharp/files/Core_Rodin_Platform/${RODIN_VERSION}/${RODIN_TARBALL}/download"; \
    fi \
    && echo "Installing Rodin $RODIN_VERSION: $RODIN_TARBALL" \
    && curl -fSL --retry 3 --retry-delay 5 --max-time 300 \
        -o /tmp/rodin.tar.gz "$RODIN_URL" \
    && mkdir -p /opt/rodin \
    && tar xzf /tmp/rodin.tar.gz -C /opt/rodin --strip-components=1 \
    && rm /tmp/rodin.tar.gz /tmp/rodin-version.sh \
    && chmod +x /opt/rodin/rodin \
    && sed -i '1i -vm\n/opt/java/openjdk/bin' /opt/rodin/rodin.ini

# ── Install ProB CLI + Rodin plugins (ProB, SMT, Atelier B) ──────
# PROB_VERSION: "latest" (default) or a specific version like "1.15.1"
ARG PROB_VERSION=latest

# ProB plugin requires org.eclipse.gef which is not in Rodin's base install.
# The matching Eclipse release site provides version-compatible GEF.
# Eclipse version is read from Rodin's .eclipseproduct and mapped to a release name
# using the quarterly cadence: 4.24=2022-06, each +1 minor = +3 months.
RUN prob_env="$(/tmp/prob-version.sh "$PROB_VERSION")" \
    && eval "$prob_env" \
    && echo "Installing ProB $PROB_VERSION" \
    && curl -fSL --retry 3 --retry-delay 5 --max-time 300 \
        -o /tmp/prob.tar.gz "$PROB_URL" \
    && mkdir -p /opt/prob \
    && tar xzf /tmp/prob.tar.gz -C /opt/prob --strip-components=1 \
    && rm /tmp/prob.tar.gz /tmp/prob-version.sh \
    && ln -s /opt/prob/probcli /usr/local/bin/probcli \
    && ECLIPSE_MINOR=$(grep '^version=' /opt/rodin/.eclipseproduct | cut -d. -f2) \
    && OFFSET=$(( ECLIPSE_MINOR - 24 )) \
    && TOTAL_MONTHS=$(( 5 + OFFSET * 3 )) \
    && ECLIPSE_RELEASE="$(( 2022 + TOTAL_MONTHS / 12 ))-$(printf "%02d" $(( TOTAL_MONTHS % 12 + 1 )))" \
    && echo "Using Eclipse release $ECLIPSE_RELEASE for dependencies (platform 4.$ECLIPSE_MINOR)" \
    && java -jar /opt/rodin/plugins/org.eclipse.equinox.launcher_*.jar \
        -nosplash \
        -application org.eclipse.equinox.p2.director \
        -repository "https://rodin-b-sharp.sourceforge.net/updates/,https://www.atelierb.eu/update_site/atelierb_provers,https://stups.hhu-hosting.de/rodin/prob1/release/,https://download.eclipse.org/releases/$ECLIPSE_RELEASE/" \
        -installIU org.eventb.smt.feature.group,com.clearsy.atelierb.provers.feature.group,de.prob2.feature.feature.group,de.prob2.disprover.feature.feature.group,de.prob2.symbolic.feature.feature.group \
        -destination /opt/rodin

# ── Runtime configuration ──────────────────────────────────────────
COPY --chmod=755 rodin-headless.sh rodin-headless-lib.sh entrypoint.sh \
    /usr/local/bin/

ENV RODIN_DIR=/opt/rodin
ENV MODELS_DIR=/models

WORKDIR /models
ENTRYPOINT ["entrypoint.sh"]
