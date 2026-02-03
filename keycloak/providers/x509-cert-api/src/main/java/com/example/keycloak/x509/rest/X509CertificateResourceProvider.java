package com.example.keycloak.x509.rest;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;

/**
 * Resource provider that exposes the X509 Certificate API at the realm level.
 * The API will be available at: /realms/{realm}/x509-cert-api/
 */
public class X509CertificateResourceProvider implements RealmResourceProvider {

    private final KeycloakSession session;

    public X509CertificateResourceProvider(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public Object getResource() {
        return new X509CertificateResource(session);
    }

    @Override
    public void close() {
        // Nothing to close
    }
}
