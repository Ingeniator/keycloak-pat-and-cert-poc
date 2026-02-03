package com.example.keycloak.x509.auth;

import org.keycloak.Config;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.provider.ProviderConfigurationBuilder;

import java.util.List;

/**
 * Factory for X509UserAttributeAuthenticator.
 * This authenticator looks up users by their registered certificate fingerprint.
 * Supports email fallback for CA-signed certificates.
 */
public class X509UserAttributeAuthenticatorFactory implements AuthenticatorFactory {

    public static final String PROVIDER_ID = "x509-user-attribute-authenticator";
    private static final X509UserAttributeAuthenticator SINGLETON = new X509UserAttributeAuthenticator();

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES;

    static {
        CONFIG_PROPERTIES = ProviderConfigurationBuilder.create()
                .property()
                    .name(X509UserAttributeAuthenticator.CONFIG_EMAIL_FALLBACK_ENABLED)
                    .label("Enable Email Fallback")
                    .helpText("If enabled, when no user is found by certificate fingerprint, " +
                            "the authenticator will extract the email from the certificate and " +
                            "try to find a user with matching email. Requires a trusted CA certificate " +
                            "to be configured below. Self-signed certificates cannot use email fallback.")
                    .type(ProviderConfigProperty.BOOLEAN_TYPE)
                    .defaultValue("true")
                    .add()
                .property()
                    .name(X509UserAttributeAuthenticator.CONFIG_AUTO_REGISTER_CERT)
                    .label("Auto-register Certificate on Email Match")
                    .helpText("If enabled, when a user is found via email fallback, " +
                            "the certificate fingerprint will be automatically registered " +
                            "for the user, allowing direct fingerprint matching on future logins.")
                    .type(ProviderConfigProperty.BOOLEAN_TYPE)
                    .defaultValue("true")
                    .add()
                .property()
                    .name(X509UserAttributeAuthenticator.CONFIG_TRUSTED_CA_CERTIFICATE)
                    .label("Trusted CA Certificate(s) (Optional)")
                    .helpText("PEM-encoded CA certificate(s) trusted for email fallback authentication. " +
                            "RECOMMENDED: Use environment variable X509_TRUSTED_CA_CERT_PATH instead to specify " +
                            "the file path to CA certificate(s). This field is only used if the environment " +
                            "variable is not set. Self-signed certificates will only work with fingerprint matching.")
                    .type(ProviderConfigProperty.TEXT_TYPE)
                    .add()
                .build();
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "X.509/Certificate User Attribute";
    }

    @Override
    public String getReferenceCategory() {
        return "x509";
    }

    @Override
    public boolean isConfigurable() {
        return true;
    }

    @Override
    public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return new AuthenticationExecutionModel.Requirement[]{
                AuthenticationExecutionModel.Requirement.REQUIRED,
                AuthenticationExecutionModel.Requirement.ALTERNATIVE,
                AuthenticationExecutionModel.Requirement.DISABLED
        };
    }

    @Override
    public boolean isUserSetupAllowed() {
        return false;
    }

    @Override
    public String getHelpText() {
        return "Authenticates users by matching their X.509 client certificate fingerprint " +
                "against registered certificates stored in user attributes. " +
                "Similar to GitHub's SSH key authentication. " +
                "Supports email fallback: if fingerprint is not found, extract email from " +
                "certificate and match against user email in Keycloak.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    public Authenticator create(KeycloakSession session) {
        return SINGLETON;
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
