package com.example.keycloak.x509.rest;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.services.managers.AppAuthManager;
import org.keycloak.services.managers.AuthenticationManager;

import java.io.ByteArrayInputStream;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.*;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * REST Resource for managing X.509 certificates associated with user accounts.
 * Similar to GitHub's SSH key management, users can add their public certificates
 * to authenticate via X.509 client certificates.
 */
public class X509CertificateResource {

    private static final Logger LOGGER = Logger.getLogger(X509CertificateResource.class.getName());

    private static final String ATTR_X509_PUBLIC_KEY = "x509_certificate_public_key";
    private static final String ATTR_X509_SUBJECT_DN = "x509_certificate_subject_dn";
    private static final String ATTR_X509_FINGERPRINT = "x509_certificate_fingerprint";
    private static final String ATTR_X509_NOT_BEFORE = "x509_certificate_not_before";
    private static final String ATTR_X509_NOT_AFTER = "x509_certificate_not_after";
    private static final String ATTR_X509_SERIAL = "x509_certificate_serial";
    private static final String ATTR_X509_ISSUER_DN = "x509_certificate_issuer_dn";
    private static final String ATTR_X509_CERT_PEM = "x509_certificate_pem";
    private static final String ATTR_X509_TITLE = "x509_certificate_title";

    private final KeycloakSession session;
    private final AuthenticationManager.AuthResult auth;

    public X509CertificateResource(KeycloakSession session) {
        this.session = session;
        this.auth = new AppAuthManager.BearerTokenAuthenticator(session).authenticate();
    }

    /**
     * Get all certificates for the authenticated user
     */
    @GET
    @Path("/certificates")
    @Produces(MediaType.APPLICATION_JSON)
    public Response getCertificates() {
        UserModel user = getAuthenticatedUser();
        if (user == null) {
            return Response.status(Response.Status.UNAUTHORIZED)
                    .entity(Map.of("error", "Authentication required"))
                    .build();
        }

        List<Map<String, Object>> certificates = new ArrayList<>();
        List<String> fingerprints = user.getAttributeStream(ATTR_X509_FINGERPRINT).toList();
        List<String> subjectDns = user.getAttributeStream(ATTR_X509_SUBJECT_DN).toList();
        List<String> titles = user.getAttributeStream(ATTR_X509_TITLE).toList();
        List<String> notBefores = user.getAttributeStream(ATTR_X509_NOT_BEFORE).toList();
        List<String> notAfters = user.getAttributeStream(ATTR_X509_NOT_AFTER).toList();

        for (int i = 0; i < fingerprints.size(); i++) {
            Map<String, Object> cert = new HashMap<>();
            cert.put("id", fingerprints.get(i));
            cert.put("fingerprint", fingerprints.get(i));
            cert.put("subject_dn", i < subjectDns.size() ? subjectDns.get(i) : "");
            cert.put("title", i < titles.size() ? titles.get(i) : "");
            cert.put("not_before", i < notBefores.size() ? notBefores.get(i) : "");
            cert.put("not_after", i < notAfters.size() ? notAfters.get(i) : "");
            certificates.add(cert);
        }

        return Response.ok(Map.of(
                "certificates", certificates,
                "count", certificates.size()
        )).build();
    }

    /**
     * Add a new certificate for the authenticated user
     * Accepts PEM-encoded X.509 certificate
     */
    @POST
    @Path("/certificates")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response addCertificate(CertificateRequest request) {
        UserModel user = getAuthenticatedUser();
        if (user == null) {
            return Response.status(Response.Status.UNAUTHORIZED)
                    .entity(Map.of("error", "Authentication required"))
                    .build();
        }

        if (request == null || request.certificate == null || request.certificate.isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Certificate is required"))
                    .build();
        }

        try {
            // Parse the certificate
            X509Certificate cert = parseCertificate(request.certificate);

            // Calculate fingerprint
            String fingerprint = calculateFingerprint(cert);

            // Check if certificate already exists
            List<String> existingFingerprints = user.getAttributeStream(ATTR_X509_FINGERPRINT).toList();
            if (existingFingerprints.contains(fingerprint)) {
                return Response.status(Response.Status.CONFLICT)
                        .entity(Map.of("error", "Certificate already registered"))
                        .build();
            }

            // Extract certificate info
            String subjectDn = cert.getSubjectX500Principal().getName();
            String issuerDn = cert.getIssuerX500Principal().getName();
            String serial = cert.getSerialNumber().toString(16);
            String notBefore = cert.getNotBefore().toInstant().toString();
            String notAfter = cert.getNotAfter().toInstant().toString();
            String publicKeyPem = encodePublicKey(cert.getPublicKey());
            String title = request.title != null ? request.title : extractCommonName(subjectDn);

            // Store certificate attributes
            addAttribute(user, ATTR_X509_FINGERPRINT, fingerprint);
            addAttribute(user, ATTR_X509_PUBLIC_KEY, publicKeyPem);
            addAttribute(user, ATTR_X509_SUBJECT_DN, subjectDn);
            addAttribute(user, ATTR_X509_ISSUER_DN, issuerDn);
            addAttribute(user, ATTR_X509_SERIAL, serial);
            addAttribute(user, ATTR_X509_NOT_BEFORE, notBefore);
            addAttribute(user, ATTR_X509_NOT_AFTER, notAfter);
            addAttribute(user, ATTR_X509_CERT_PEM, normalizePem(request.certificate));
            addAttribute(user, ATTR_X509_TITLE, title);

            LOGGER.info("Certificate added for user " + user.getUsername() + " with fingerprint " + fingerprint);

            return Response.status(Response.Status.CREATED)
                    .entity(Map.of(
                            "id", fingerprint,
                            "fingerprint", fingerprint,
                            "subject_dn", subjectDn,
                            "issuer_dn", issuerDn,
                            "serial", serial,
                            "not_before", notBefore,
                            "not_after", notAfter,
                            "title", title,
                            "message", "Certificate added successfully"
                    )).build();

        } catch (Exception e) {
            LOGGER.log(Level.WARNING, "Failed to add certificate", e);
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Invalid certificate: " + e.getMessage()))
                    .build();
        }
    }

    /**
     * Delete a certificate by fingerprint
     */
    @DELETE
    @Path("/certificates/{fingerprint}")
    @Produces(MediaType.APPLICATION_JSON)
    public Response deleteCertificate(@PathParam("fingerprint") String fingerprint) {
        UserModel user = getAuthenticatedUser();
        if (user == null) {
            return Response.status(Response.Status.UNAUTHORIZED)
                    .entity(Map.of("error", "Authentication required"))
                    .build();
        }

        List<String> fingerprints = new ArrayList<>(user.getAttributeStream(ATTR_X509_FINGERPRINT).toList());
        int index = fingerprints.indexOf(fingerprint);

        if (index == -1) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(Map.of("error", "Certificate not found"))
                    .build();
        }

        // Remove from all attribute lists at the same index
        removeAttributeAtIndex(user, ATTR_X509_FINGERPRINT, index);
        removeAttributeAtIndex(user, ATTR_X509_PUBLIC_KEY, index);
        removeAttributeAtIndex(user, ATTR_X509_SUBJECT_DN, index);
        removeAttributeAtIndex(user, ATTR_X509_ISSUER_DN, index);
        removeAttributeAtIndex(user, ATTR_X509_SERIAL, index);
        removeAttributeAtIndex(user, ATTR_X509_NOT_BEFORE, index);
        removeAttributeAtIndex(user, ATTR_X509_NOT_AFTER, index);
        removeAttributeAtIndex(user, ATTR_X509_CERT_PEM, index);
        removeAttributeAtIndex(user, ATTR_X509_TITLE, index);

        LOGGER.info("Certificate deleted for user " + user.getUsername() + " with fingerprint " + fingerprint);

        return Response.ok(Map.of("message", "Certificate deleted successfully")).build();
    }

    /**
     * Verify if a certificate matches any registered for the authenticated user
     */
    @POST
    @Path("/certificates/verify")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response verifyCertificate(CertificateRequest request) {
        UserModel user = getAuthenticatedUser();
        if (user == null) {
            return Response.status(Response.Status.UNAUTHORIZED)
                    .entity(Map.of("error", "Authentication required"))
                    .build();
        }

        if (request == null || request.certificate == null || request.certificate.isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Certificate is required"))
                    .build();
        }

        try {
            X509Certificate cert = parseCertificate(request.certificate);
            String fingerprint = calculateFingerprint(cert);

            List<String> existingFingerprints = user.getAttributeStream(ATTR_X509_FINGERPRINT).toList();
            boolean isValid = existingFingerprints.contains(fingerprint);

            return Response.ok(Map.of(
                    "valid", isValid,
                    "fingerprint", fingerprint,
                    "subject_dn", cert.getSubjectX500Principal().getName()
            )).build();

        } catch (Exception e) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Invalid certificate: " + e.getMessage()))
                    .build();
        }
    }

    // --- Helper methods ---

    private UserModel getAuthenticatedUser() {
        if (auth == null) {
            return null;
        }
        return auth.getUser();
    }

    private X509Certificate parseCertificate(String pemCert) throws Exception {
        String normalized = normalizePem(pemCert);
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        return (X509Certificate) factory.generateCertificate(
                new ByteArrayInputStream(normalized.getBytes())
        );
    }

    private String normalizePem(String pem) {
        // Remove any extra whitespace and ensure proper PEM format
        String cert = pem.trim();
        if (!cert.startsWith("-----BEGIN")) {
            cert = "-----BEGIN CERTIFICATE-----\n" + cert;
        }
        if (!cert.endsWith("-----")) {
            cert = cert + "\n-----END CERTIFICATE-----";
        }
        return cert;
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

    private String encodePublicKey(PublicKey publicKey) {
        return Base64.getEncoder().encodeToString(publicKey.getEncoded());
    }

    private String extractCommonName(String dn) {
        for (String part : dn.split(",")) {
            String trimmed = part.trim();
            if (trimmed.startsWith("CN=")) {
                return trimmed.substring(3);
            }
        }
        return dn;
    }

    private void addAttribute(UserModel user, String attrName, String value) {
        List<String> values = new ArrayList<>(user.getAttributeStream(attrName).toList());
        values.add(value);
        user.setAttribute(attrName, values);
    }

    private void removeAttributeAtIndex(UserModel user, String attrName, int index) {
        List<String> values = new ArrayList<>(user.getAttributeStream(attrName).toList());
        if (index < values.size()) {
            values.remove(index);
            user.setAttribute(attrName, values);
        }
    }

    // --- Request/Response classes ---

    public static class CertificateRequest {
        public String certificate;
        public String title;
    }
}
