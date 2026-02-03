package com.example.keycloak.x509.auth;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.services.x509.X509ClientCertificateLookup;

import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.List;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.stream.Stream;

/**
 * Custom X.509 authenticator that looks up users by their registered certificate fingerprint.
 * This enables GitHub-like certificate authentication where users register their certificates
 * via the API and then authenticate using those certificates.
 */
public class X509UserAttributeAuthenticator implements Authenticator {

    private static final Logger LOGGER = Logger.getLogger(X509UserAttributeAuthenticator.class.getName());
    private static final String ATTR_X509_FINGERPRINT = "x509_certificate_fingerprint";

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        try {
            // Get client certificate
            X509Certificate[] certs = getCertificateChain(context);
            if (certs == null || certs.length == 0) {
                LOGGER.fine("No client certificate provided");
                context.attempted();
                return;
            }

            X509Certificate clientCert = certs[0];
            String fingerprint = calculateFingerprint(clientCert);
            LOGGER.info("Client certificate presented with fingerprint: " + fingerprint);

            // Look up user by certificate fingerprint
            UserModel user = findUserByFingerprint(context.getSession(), context.getRealm(), fingerprint);

            if (user == null) {
                LOGGER.warning("No user found with certificate fingerprint: " + fingerprint);
                context.getEvent().error("user_not_found");
                context.failure(AuthenticationFlowError.INVALID_USER);
                return;
            }

            if (!user.isEnabled()) {
                LOGGER.warning("User " + user.getUsername() + " is disabled");
                context.getEvent().error("user_disabled");
                context.failure(AuthenticationFlowError.USER_DISABLED);
                return;
            }

            LOGGER.info("User " + user.getUsername() + " authenticated via X.509 certificate");
            context.setUser(user);
            context.success();

        } catch (Exception e) {
            LOGGER.log(Level.SEVERE, "X.509 authentication failed", e);
            context.failure(AuthenticationFlowError.INTERNAL_ERROR);
        }
    }

    @Override
    public void action(AuthenticationFlowContext context) {
        // No action needed - authentication happens in authenticate()
    }

    @Override
    public boolean requiresUser() {
        return false;
    }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) {
        return true;
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) {
        // No required actions
    }

    @Override
    public void close() {
        // Nothing to close
    }

    protected X509Certificate[] getCertificateChain(AuthenticationFlowContext context) {
        try {
            X509ClientCertificateLookup lookup = context.getSession()
                    .getProvider(X509ClientCertificateLookup.class);
            if (lookup == null) {
                LOGGER.warning("X509ClientCertificateLookup provider not found");
                return null;
            }
            return lookup.getCertificateChain(context.getHttpRequest());
        } catch (Exception e) {
            LOGGER.log(Level.WARNING, "Failed to get certificate chain", e);
            return null;
        }
    }

    private String calculateFingerprint(X509Certificate cert) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] digest = md.digest(cert.getEncoded());
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < digest.length; i++) {
            if (i > 0) sb.append(":");
            sb.append(String.format("%02X", digest[i]));
        }
        return sb.toString();
    }

    private UserModel findUserByFingerprint(KeycloakSession session, RealmModel realm, String fingerprint) {
        // Search for users with matching fingerprint in their attributes
        Stream<UserModel> users = session.users().searchForUserByUserAttributeStream(
                realm, ATTR_X509_FINGERPRINT, fingerprint);

        List<UserModel> matchingUsers = users.toList();

        if (matchingUsers.isEmpty()) {
            return null;
        }

        if (matchingUsers.size() > 1) {
            LOGGER.warning("Multiple users found with same certificate fingerprint: " + fingerprint);
        }

        return matchingUsers.get(0);
    }
}
