# Multi-stage build: pre-build Keycloak with providers + build-time options,
# then run with `start --optimized` for production-grade throughput.
FROM quay.io/keycloak/keycloak:24.0 AS builder

# Build-time options (baked into the optimized image)
ENV KC_DB=postgres
ENV KC_FEATURES=preview
ENV KC_HTTP_ENABLED=true
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_HTTPS_CLIENT_AUTH=request
ENV KC_SPI_X509CERT_LOOKUP_PROVIDER=nginx

# Custom SPI providers (x509 cert lookup, PAT API)
COPY providers/ /opt/keycloak/providers/
COPY conf/quarkus.properties /opt/keycloak/conf/quarkus.properties

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:24.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
