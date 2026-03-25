FROM docker.io/eclipse-temurin:21-jdk-jammy

LABEL description="Rodin Event-B IDE headless builder"

# ── System dependencies ─────────────────────────────────────────────
# GTK3 + X11 libs: SWT runtime requires these even headless
# xvfb: virtual framebuffer for headless SWT/Eclipse
# fonts: Eclipse/SWT needs at least one font available
# zip/unzip: model archive handling
# curl: downloading Rodin tarball
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
    && rm -rf /var/lib/apt/lists/*

# ── Download and install Rodin ──────────────────────────────────────
# RODIN_VERSION: "latest" (default), "latest-rc", or a specific version like "3.9"
# RODIN_TARBALL: auto-detected from SourceForge, or override with full filename
ARG RODIN_VERSION=latest
ARG RODIN_TARBALL=

COPY --chmod=755 rodin-version.sh /tmp/rodin-version.sh
COPY --chmod=755 rodin-headless-build.sh /usr/local/bin/rodin-headless-build.sh

RUN if [ -z "$RODIN_TARBALL" ]; then \
        eval "$(/tmp/rodin-version.sh "$RODIN_VERSION")"; \
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

# ── Runtime configuration ──────────────────────────────────────────
ENV RODIN_DIR=/opt/rodin
ENV MODELS_DIR=/models

WORKDIR /models
ENTRYPOINT ["rodin-headless-build.sh"]
