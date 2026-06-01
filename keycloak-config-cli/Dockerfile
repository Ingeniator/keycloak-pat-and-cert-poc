##############################################################################
# Adjustable build arguments – override every value for your internal network
#
# docker build \
#   --build-arg REGISTRY=nexus.corp.local:5000/ \
#   --build-arg MAVEN_MIRROR=https://nexus.corp.local/repository/maven-public \
#   --build-arg SOURCE_URL=https://git.corp.local/mirrors/keycloak-config-cli/archive/v6.5.0.tar.gz \
#   -t my-registry/keycloak-config-cli:6.5.0-24 .
##############################################################################

# Internal registry prefix, e.g. "nexus.corp.local:5000/"  (keep empty for public)
ARG REGISTRY=""

# UBI9 images – mirror these to your internal registry
ARG BUILD_IMAGE=registry.access.redhat.com/ubi9/openjdk-21:1.20
ARG RUNTIME_IMAGE=registry.access.redhat.com/ubi9/openjdk-21-runtime:1.20

ARG KC_CONFIG_CLI_VERSION=6.5.0
ARG KEYCLOAK_MAJOR_VERSION=24

# Source archive – point to an internal HTTP mirror when there is no internet
ARG SOURCE_URL=https://github.com/adorsys/keycloak-config-cli/archive/refs/tags/v${KC_CONFIG_CLI_VERSION}.tar.gz

# Maven mirror (Nexus / Artifactory repository group URL)
ARG MAVEN_MIRROR=https://repo1.maven.org/maven2

##############################################################################
# Stage 1 – build
#   Base image already contains: JDK 21, Maven 3.x, git
##############################################################################
FROM ${REGISTRY}${BUILD_IMAGE} AS builder

ARG KC_CONFIG_CLI_VERSION
ARG KEYCLOAK_MAJOR_VERSION
ARG SOURCE_URL
ARG MAVEN_MIRROR

USER root

# ── Custom YUM repositories ───────────────────────────────────────────────
# Place your *.repo files in repos/ next to this Dockerfile.
# When repos/ is empty the COPY is a no-op; the shell guard skips dnf config.
COPY repos/ /tmp/repos/
RUN set -eux; \
    COUNT=$(find /tmp/repos -maxdepth 1 -name '*.repo' 2>/dev/null | wc -l); \
    if [ "$COUNT" -gt 0 ]; then \
        cp /tmp/repos/*.repo /etc/yum.repos.d/; \
        # Disable default UBI repos so only internal repos are used:
        dnf config-manager --disable ubi-9-for-x86_64-appstream-rpms \
                           ubi-9-for-x86_64-baseos-rpms 2>/dev/null || true; \
    fi; \
    rm -rf /tmp/repos

# ── (Optional) Trust internal CA certificates ─────────────────────────────
# Place *.crt / *.pem files in certs/ next to this Dockerfile, then uncomment:
#
# COPY certs/ /etc/pki/ca-trust/source/anchors/
# RUN update-ca-trust extract

# ── Maven settings (inject internal mirror) ───────────────────────────────
COPY maven-settings.xml /tmp/maven-settings.xml

# Substitute the placeholder with the actual mirror URL at build time
RUN sed "s|__MAVEN_MIRROR__|${MAVEN_MIRROR}|g" \
        /tmp/maven-settings.xml > /root/.m2/settings.xml

# ── Source code ───────────────────────────────────────────────────────────
# Option A (default): fetch from URL – works when the URL is reachable or
#   proxied via an internal artifact server.
ADD ${SOURCE_URL} /tmp/src.tar.gz
RUN mkdir -p /build && \
    tar -xzf /tmp/src.tar.gz -C /build --strip-components=1 && \
    rm /tmp/src.tar.gz

# Option B: COPY local checkout – uncomment and remove the ADD block above
#   when building fully offline from a checked-out source tree.
#
# COPY src/ /build/

WORKDIR /build

# ── Build ─────────────────────────────────────────────────────────────────
RUN mvn -B package \
        --settings /root/.m2/settings.xml \
        -DskipTests \
        -Dspring-boot.build-image.skip=true \
        2>&1 | tail -30 \
    && ls -lh target/keycloak-config-cli-*.jar

##############################################################################
# Stage 2 – lean runtime
##############################################################################
FROM ${REGISTRY}${RUNTIME_IMAGE}

ARG KC_CONFIG_CLI_VERSION
ARG KEYCLOAK_MAJOR_VERSION

LABEL org.opencontainers.image.title="keycloak-config-cli" \
      org.opencontainers.image.version="${KC_CONFIG_CLI_VERSION}-${KEYCLOAK_MAJOR_VERSION}" \
      org.opencontainers.image.description="keycloak-config-cli – internal build"

USER root

# ── Custom YUM repositories (same logic as build stage) ───────────────────
COPY repos/ /tmp/repos/
RUN set -eux; \
    COUNT=$(find /tmp/repos -maxdepth 1 -name '*.repo' 2>/dev/null | wc -l); \
    if [ "$COUNT" -gt 0 ]; then \
        cp /tmp/repos/*.repo /etc/yum.repos.d/; \
        dnf config-manager --disable ubi-9-for-x86_64-appstream-rpms \
                           ubi-9-for-x86_64-baseos-rpms 2>/dev/null || true; \
    fi; \
    rm -rf /tmp/repos

# ── (Optional) Trust internal CA certificates ─────────────────────────────
# COPY certs/ /etc/pki/ca-trust/source/anchors/
# RUN update-ca-trust extract

# ── Security patches ──────────────────────────────────────────────────────
RUN dnf upgrade -y --security --nodocs && dnf clean all

# ── Application ───────────────────────────────────────────────────────────
RUN mkdir /app
COPY --from=builder \
     /build/target/keycloak-config-cli-${KC_CONFIG_CLI_VERSION}.jar \
     /app/keycloak-config-cli.jar

RUN chown -R 1001:root /app && chmod -R g+rwX /app

USER 1001

ENV JAVA_OPTS=""

ENTRYPOINT ["/bin/sh", "-c", "exec java $JAVA_OPTS -jar /app/keycloak-config-cli.jar \"$@\"", "--"]
