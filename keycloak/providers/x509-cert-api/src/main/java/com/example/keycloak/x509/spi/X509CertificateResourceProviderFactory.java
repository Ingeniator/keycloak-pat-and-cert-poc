package com.example.keycloak.x509.spi;

import com.example.keycloak.x509.rest.X509CertificateResourceProvider;
import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

/**
 * Factory for creating X509CertificateResourceProvider instances.
 * Registers the API endpoint at /realms/{realm}/x509-cert-api/
 */
public class X509CertificateResourceProviderFactory implements RealmResourceProviderFactory {

    public static final String PROVIDER_ID = "x509-cert-api";

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        return new X509CertificateResourceProvider(session);
    }

    @Override
    public void init(Config.Scope config) {
        // No initialization needed
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // No post-initialization needed
    }

    @Override
    public void close() {
        // Nothing to close
    }
}
