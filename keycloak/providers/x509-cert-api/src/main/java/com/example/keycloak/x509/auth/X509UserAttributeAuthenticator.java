package com.example.keycloak.x509.auth;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.services.x509.X509ClientCertificateLookup;

import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.stream.Stream;

/**
 * Custom X.509 authenticator that looks up users by their registered certificate fingerprint.
 * This enables GitHub-like certificate authentication where users register their certificates
 * via the API and then authenticate using those certificates.
 *
 * Supports email fallback: if no user is found by fingerprint, the authenticator can
 * extract the email from the certificate and look up the user by email.
 */
public class X509UserAttributeAuthenticator implements Authenticator {

    private static final Logger LOGGER = Logger.getLogger(X509UserAttributeAuthenticator.class.getName());
    private static final String ATTR_X509_FINGERPRINT = "x509_certificate_fingerprint";

    // Configuration keys
    public static final String CONFIG_EMAIL_FALLBACK_ENABLED = "emailFallbackEnabled";
    public static final String CONFIG_AUTO_REGISTER_CERT = "autoRegisterCertOnEmailMatch";
    public static final String CONFIG_TRUSTED_CA_CERTIFICATE = "trustedCaCertificate";

    // Environment variable for trusted CA certificate file path
    public static final String ENV_TRUSTED_CA_CERT_PATH = "X509_TRUSTED_CA_CERT_PATH";

    // SAN type for email (rfc822Name)
    private static final int SAN_TYPE_RFC822_NAME = 1;

    // Cache for trusted CA certificates (loaded once from file)
    private static volatile List<X509Certificate> cachedTrustedCAs = null;
    private static volatile String cachedCertPath = null;

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
            boolean foundByFingerprint = (user != null);

            // Email fallback: if no user found by fingerprint, try email from certificate
            // Only allow email fallback if certificate is signed by a trusted CA
            if (user == null && isEmailFallbackEnabled(context)) {
                // First verify the certificate is signed by a trusted CA
                if (!isCertificateSignedByTrustedCA(context, clientCert)) {
                    LOGGER.info("Certificate is not signed by trusted CA, email fallback not allowed. " +
                            "Self-signed certificates must be pre-registered.");
                } else {
                    String email = extractEmailFromCertificate(clientCert);
                    if (email != null && !email.isEmpty()) {
                        LOGGER.info("CA-signed certificate verified, trying email fallback with: " + email);
                        user = context.getSession().users().getUserByEmail(context.getRealm(), email);

                        if (user != null) {
                            LOGGER.info("User found by email from certificate: " + user.getUsername());

                            // Auto-register the certificate fingerprint for future logins
                            if (isAutoRegisterEnabled(context)) {
                                autoRegisterCertificate(user, clientCert, fingerprint);
                                LOGGER.info("Auto-registered certificate fingerprint for user: " + user.getUsername());
                            }
                        }
                    } else {
                        LOGGER.warning("No email found in certificate for fallback lookup");
                    }
                }
            }

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

            String authMethod = foundByFingerprint ? "fingerprint" : "email-fallback";
            LOGGER.info("User " + user.getUsername() + " authenticated via X.509 certificate (" + authMethod + ")");
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

    /**
     * Check if email fallback is enabled in the authenticator configuration.
     */
    private boolean isEmailFallbackEnabled(AuthenticationFlowContext context) {
        Map<String, String> config = context.getAuthenticatorConfig() != null
                ? context.getAuthenticatorConfig().getConfig()
                : null;

        if (config == null) {
            return true; // Default to enabled
        }
        return Boolean.parseBoolean(config.getOrDefault(CONFIG_EMAIL_FALLBACK_ENABLED, "true"));
    }

    /**
     * Check if auto-registration of certificate on email match is enabled.
     */
    private boolean isAutoRegisterEnabled(AuthenticationFlowContext context) {
        Map<String, String> config = context.getAuthenticatorConfig() != null
                ? context.getAuthenticatorConfig().getConfig()
                : null;

        if (config == null) {
            return true; // Default to enabled
        }
        return Boolean.parseBoolean(config.getOrDefault(CONFIG_AUTO_REGISTER_CERT, "true"));
    }

    /**
     * Verify that the client certificate is signed by a trusted CA.
     * This is required for email fallback to prevent unauthorized access with self-signed certs.
     */
    private boolean isCertificateSignedByTrustedCA(AuthenticationFlowContext context, X509Certificate clientCert) {
        List<X509Certificate> trustedCAs = getTrustedCACertificates(context);

        if (trustedCAs.isEmpty()) {
            LOGGER.warning("No trusted CA certificates configured. Email fallback requires at least one trusted CA.");
            return false;
        }

        // Check if the client certificate is signed by any of the trusted CAs
        for (X509Certificate caCert : trustedCAs) {
            try {
                // Verify the client cert was signed by this CA's public key
                clientCert.verify(caCert.getPublicKey());

                // Also check that the CA cert is valid
                caCert.checkValidity();

                // Check that the client cert is valid
                clientCert.checkValidity();

                LOGGER.fine("Certificate verified against trusted CA: " + caCert.getSubjectX500Principal().getName());
                return true;
            } catch (Exception e) {
                // This CA didn't sign the cert, try the next one
                LOGGER.fine("Certificate not signed by CA: " + caCert.getSubjectX500Principal().getName() +
                        " - " + e.getMessage());
            }
        }

        LOGGER.fine("Certificate not signed by any trusted CA");
        return false;
    }

    /**
     * Get the list of trusted CA certificates.
     * Priority:
     * 1. Environment variable X509_TRUSTED_CA_CERT_PATH (file path)
     * 2. Authenticator config (inline PEM)
     */
    private List<X509Certificate> getTrustedCACertificates(AuthenticationFlowContext context) {
        // First, try environment variable with file path
        String certPath = System.getenv(ENV_TRUSTED_CA_CERT_PATH);
        if (certPath != null && !certPath.trim().isEmpty()) {
            return loadCertificatesFromFile(certPath);
        }

        // Fallback to inline PEM in authenticator config
        Map<String, String> config = context.getAuthenticatorConfig() != null
                ? context.getAuthenticatorConfig().getConfig()
                : null;

        if (config == null) {
            return List.of();
        }

        String caCertPem = config.get(CONFIG_TRUSTED_CA_CERTIFICATE);
        if (caCertPem == null || caCertPem.trim().isEmpty()) {
            return List.of();
        }

        return parseCertificates(caCertPem);
    }

    /**
     * Load CA certificates from a file path.
     * Caches the result to avoid reading the file on every request.
     */
    private List<X509Certificate> loadCertificatesFromFile(String certPath) {
        // Check cache - if path hasn't changed, return cached certs
        if (cachedTrustedCAs != null && certPath.equals(cachedCertPath)) {
            return cachedTrustedCAs;
        }

        synchronized (X509UserAttributeAuthenticator.class) {
            // Double-check after acquiring lock
            if (cachedTrustedCAs != null && certPath.equals(cachedCertPath)) {
                return cachedTrustedCAs;
            }

            try {
                Path path = Paths.get(certPath);
                if (!Files.exists(path)) {
                    LOGGER.warning("Trusted CA certificate file not found: " + certPath);
                    return List.of();
                }

                String pemContent = Files.readString(path, StandardCharsets.UTF_8);
                List<X509Certificate> certs = parseCertificates(pemContent);

                if (!certs.isEmpty()) {
                    LOGGER.info("Loaded " + certs.size() + " trusted CA certificate(s) from: " + certPath);
                    cachedTrustedCAs = certs;
                    cachedCertPath = certPath;
                }

                return certs;
            } catch (Exception e) {
                LOGGER.log(Level.SEVERE, "Failed to load trusted CA certificates from: " + certPath, e);
                return List.of();
            }
        }
    }

    /**
     * Parse one or more PEM-encoded certificates from a string.
     * Supports multiple certificates concatenated in a single string.
     */
    private List<X509Certificate> parseCertificates(String pemData) {
        List<X509Certificate> certificates = new ArrayList<>();

        try {
            CertificateFactory cf = CertificateFactory.getInstance("X.509");

            // Split by certificate boundaries to handle multiple certs
            String[] certBlocks = pemData.split("(?=-----BEGIN CERTIFICATE-----)");

            for (String certBlock : certBlocks) {
                certBlock = certBlock.trim();
                if (certBlock.isEmpty() || !certBlock.contains("-----BEGIN CERTIFICATE-----")) {
                    continue;
                }

                try {
                    ByteArrayInputStream bis = new ByteArrayInputStream(
                            certBlock.getBytes(StandardCharsets.UTF_8));
                    X509Certificate cert = (X509Certificate) cf.generateCertificate(bis);
                    certificates.add(cert);
                    LOGGER.fine("Loaded trusted CA certificate: " + cert.getSubjectX500Principal().getName());
                } catch (Exception e) {
                    LOGGER.log(Level.WARNING, "Failed to parse CA certificate block", e);
                }
            }
        } catch (Exception e) {
            LOGGER.log(Level.SEVERE, "Failed to initialize certificate factory", e);
        }

        return certificates;
    }

    /**
     * Extract email address from X.509 certificate.
     * Tries Subject Alternative Name (SAN) first, then falls back to Subject DN.
     */
    private String extractEmailFromCertificate(X509Certificate cert) {
        // Try Subject Alternative Name (SAN) first - this is the preferred location
        try {
            Collection<List<?>> sans = cert.getSubjectAlternativeNames();
            if (sans != null) {
                for (List<?> san : sans) {
                    if (san.size() >= 2) {
                        Integer type = (Integer) san.get(0);
                        if (type == SAN_TYPE_RFC822_NAME) {
                            String email = (String) san.get(1);
                            LOGGER.fine("Found email in SAN: " + email);
                            return email;
                        }
                    }
                }
            }
        } catch (Exception e) {
            LOGGER.log(Level.FINE, "Error reading SAN from certificate", e);
        }

        // Fallback to Subject DN
        try {
            String subjectDN = cert.getSubjectX500Principal().getName();
            LOGGER.fine("Parsing Subject DN for email: " + subjectDN);

            // Parse the DN using LdapName
            LdapName ldapName = new LdapName(subjectDN);
            for (Rdn rdn : ldapName.getRdns()) {
                String type = rdn.getType().toUpperCase();
                // Check for common email attribute names
                if ("EMAILADDRESS".equals(type) || "EMAIL".equals(type) ||
                    "E".equals(type) || "1.2.840.113549.1.9.1".equals(type)) {
                    String email = rdn.getValue().toString();
                    LOGGER.fine("Found email in Subject DN: " + email);
                    return email;
                }
            }
        } catch (Exception e) {
            LOGGER.log(Level.FINE, "Error parsing Subject DN for email", e);
        }

        LOGGER.fine("No email found in certificate");
        return null;
    }

    /**
     * Auto-register the certificate fingerprint for the user.
     * This allows future logins to use fingerprint matching directly.
     */
    private void autoRegisterCertificate(UserModel user, X509Certificate cert, String fingerprint) {
        try {
            // Get existing fingerprints or create new list
            List<String> existingFingerprints = user.getAttributeStream(ATTR_X509_FINGERPRINT).toList();

            // Check if fingerprint already registered
            if (existingFingerprints.contains(fingerprint)) {
                LOGGER.fine("Certificate fingerprint already registered for user: " + user.getUsername());
                return;
            }

            // Add the new fingerprint
            user.setSingleAttribute(ATTR_X509_FINGERPRINT, fingerprint);
            LOGGER.info("Registered certificate fingerprint for user " + user.getUsername() + ": " + fingerprint);

        } catch (Exception e) {
            LOGGER.log(Level.WARNING, "Failed to auto-register certificate for user: " + user.getUsername(), e);
        }
    }
}
