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

# ── Install Rodin + ProB via the shared installer ───────────────────
# The same rodin-install.sh works natively; the image just runs it with
# --prefix /opt. Two RUN layers keep the large Rodin download cached
# independently of the ProB layer.
# RODIN_VERSION: "latest" (default), "latest-rc", or a specific version like "3.9"
# RODIN_TARBALL: auto-detected from SourceForge, or override with full filename
# PROB_VERSION: "latest" (default) or a specific version like "1.15.1"
ARG RODIN_VERSION=latest
ARG RODIN_TARBALL=
ARG PROB_VERSION=latest

COPY --chmod=755 rodin-install.sh rodin-version.sh prob-version.sh rodin-headless-lib.sh \
    /tmp/install/

RUN /tmp/install/rodin-install.sh --prefix /opt --only rodin \
        --rodin-version "$RODIN_VERSION" \
        ${RODIN_TARBALL:+--rodin-tarball "$RODIN_TARBALL"}

RUN /tmp/install/rodin-install.sh --prefix /opt --only prob \
        --prob-version "$PROB_VERSION" \
    && ln -s /opt/prob/probcli /usr/local/bin/probcli \
    && rm -rf /tmp/install

# ── Runtime configuration ──────────────────────────────────────────
COPY --chmod=755 rodin-headless.sh rodin-headless-lib.sh entrypoint.sh \
    /usr/local/bin/

ENV RODIN_DIR=/opt/rodin
ENV MODELS_DIR=/models

WORKDIR /models
ENTRYPOINT ["entrypoint.sh"]
