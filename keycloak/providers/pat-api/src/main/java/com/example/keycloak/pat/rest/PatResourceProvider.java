package com.example.keycloak.pat.rest;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;

public class PatResourceProvider implements RealmResourceProvider {

    private final KeycloakSession session;

    public PatResourceProvider(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public Object getResource() {
        return new PatResource(session);
    }

    @Override
    public void close() {
    }
}
