package com.example.keycloak.pat.rest;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.keycloak.models.*;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.protocol.oidc.TokenManager;
import org.keycloak.services.Urls;
import org.keycloak.services.managers.AppAuthManager;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.services.util.DefaultClientSessionContext;
import com.example.keycloak.pat.spi.PatResourceProviderFactory;
import java.math.BigInteger;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.*;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.stream.Stream;

public class PatResource {

    private static final Logger LOGGER = Logger.getLogger(PatResource.class.getName());

    private static final String ATTR_PAT_ID = "pat_id";
    private static final String ATTR_PAT_NAME = "pat_name";
    private static final String ATTR_PAT_HASH = "pat_hash";
    private static final String ATTR_PAT_SCOPES = "pat_scopes";
    private static final String ATTR_PAT_CREATED_AT = "pat_created_at";
    private static final String ATTR_PAT_EXPIRES_AT = "pat_expires_at";
    private static final String ATTR_PAT_LAST_USED_AT = "pat_last_used_at";

    private static final int MAX_PATS_PER_USER = 10;
    private static final String BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

    private final KeycloakSession session;
    private final AuthenticationManager.AuthResult auth;

    public PatResource(KeycloakSession session) {
        this.session = session;
        this.auth = new AppAuthManager.BearerTokenAuthenticator(session).authenticate();
    }

    @GET
    @Path("/tokens")
    @Produces(MediaType.APPLICATION_JSON)
    public Response listTokens() {
        UserModel user = getAuthenticatedUser();
        if (user == null) {
            return unauthorized();
        }

        List<String> ids = new ArrayList<>(user.getAttributeStream(ATTR_PAT_ID).toList());
        List<String> names = new ArrayList<>(user.getAttributeStream(ATTR_PAT_NAME).toList());
        List<String> hashes = new ArrayList<>(user.getAttributeStream(ATTR_PAT_HASH).toList());
        List<String> scopes = new ArrayList<>(user.getAttributeStream(ATTR_PAT_SCOPES).toList());
        List<String> createdAts = new ArrayList<>(user.getAttributeStream(ATTR_PAT_CREATED_AT).toList());
        List<String> expiresAts = new ArrayList<>(user.getAttributeStream(ATTR_PAT_EXPIRES_AT).toList());
        List<String> lastUsedAts = new ArrayList<>(user.getAttributeStream(ATTR_PAT_LAST_USED_AT).toList());

        // Lazy cleanup: collect indices of expired tokens (reverse order for safe removal)
        List<Integer> expiredIndices = new ArrayList<>();
        Instant now = Instant.now();
        for (int i = 0; i < ids.size(); i++) {
            if (i < expiresAts.size() && !"never".equals(expiresAts.get(i))) {
                try {
                    if (now.isAfter(Instant.parse(expiresAts.get(i)))) {
                        expiredIndices.add(i);
                    }
                } catch (Exception ignored) {
                }
            }
        }

        // Remove expired tokens from attributes (reverse order to preserve indices)
        if (!expiredIndices.isEmpty()) {
            for (int i = expiredIndices.size() - 1; i >= 0; i--) {
                int idx = expiredIndices.get(i);
                if (idx < ids.size()) ids.remove(idx);
                if (idx < names.size()) names.remove(idx);
                if (idx < hashes.size()) hashes.remove(idx);
                if (idx < scopes.size()) scopes.remove(idx);
                if (idx < createdAts.size()) createdAts.remove(idx);
                if (idx < expiresAts.size()) expiresAts.remove(idx);
                if (idx < lastUsedAts.size()) lastUsedAts.remove(idx);
            }
            user.setAttribute(ATTR_PAT_ID, ids);
            user.setAttribute(ATTR_PAT_NAME, names);
            user.setAttribute(ATTR_PAT_HASH, hashes);
            user.setAttribute(ATTR_PAT_SCOPES, scopes);
            user.setAttribute(ATTR_PAT_CREATED_AT, createdAts);
            user.setAttribute(ATTR_PAT_EXPIRES_AT, expiresAts);
            user.setAttribute(ATTR_PAT_LAST_USED_AT, lastUsedAts);
            LOGGER.info("Cleaned up " + expiredIndices.size() + " expired PAT(s) for user " + user.getUsername());
        }

        List<Map<String, Object>> tokens = new ArrayList<>();
        for (int i = 0; i < ids.size(); i++) {
            Map<String, Object> token = new LinkedHashMap<>();
            token.put("id", ids.get(i));
            token.put("name", i < names.size() ? names.get(i) : "");
            token.put("scopes", i < scopes.size() ? scopes.get(i) : "");
            token.put("created_at", i < createdAts.size() ? createdAts.get(i) : "");
            token.put("expires_at", i < expiresAts.size() ? expiresAts.get(i) : "never");
            token.put("last_used_at", i < lastUsedAts.size() ? lastUsedAts.get(i) : "never");
            tokens.add(token);
        }

        return Response.ok(Map.of("tokens", tokens, "count", tokens.size())).build();
    }

    @POST
    @Path("/tokens")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response createToken(CreateTokenRequest request) {
        UserModel user = getAuthenticatedUser();
        if (user == null) {
            return unauthorized();
        }

        if (request == null || request.name == null || request.name.isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Token name is required"))
                    .build();
        }

        List<String> existingIds = user.getAttributeStream(ATTR_PAT_ID).toList();
        if (existingIds.size() >= MAX_PATS_PER_USER) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Maximum " + MAX_PATS_PER_USER + " tokens allowed"))
                    .build();
        }

        try {
            String rawToken = generateToken();
            String hash = sha256Hex(rawToken);
            String id = UUID.randomUUID().toString();

            String tokenScopes = (request.scopes != null && !request.scopes.isBlank())
                    ? request.scopes : "openid profile email";
            String now = Instant.now().toString();
            String expiresAt = "never";
            if (request.expiresInDays != null && request.expiresInDays > 0) {
                expiresAt = Instant.now().plusSeconds((long) request.expiresInDays * 86400).toString();
            }

            addAttribute(user, ATTR_PAT_ID, id);
            addAttribute(user, ATTR_PAT_NAME, request.name);
            addAttribute(user, ATTR_PAT_HASH, hash);
            addAttribute(user, ATTR_PAT_SCOPES, tokenScopes);
            addAttribute(user, ATTR_PAT_CREATED_AT, now);
            addAttribute(user, ATTR_PAT_EXPIRES_AT, expiresAt);
            addAttribute(user, ATTR_PAT_LAST_USED_AT, "never");

            LOGGER.info("PAT created for user " + user.getUsername() + " id=" + id + " name=" + request.name);

            return Response.status(Response.Status.CREATED)
                    .entity(Map.of(
                            "token", rawToken,
                            "id", id,
                            "name", request.name,
                            "scopes", tokenScopes,
                            "created_at", now,
                            "expires_at", expiresAt
                    )).build();

        } catch (Exception e) {
            LOGGER.log(Level.WARNING, "Failed to create PAT", e);
            return Response.status(Response.Status.INTERNAL_SERVER_ERROR)
                    .entity(Map.of("error", "Failed to create token"))
                    .build();
        }
    }

    @DELETE
    @Path("/tokens/{id}")
    @Produces(MediaType.APPLICATION_JSON)
    public Response deleteToken(@PathParam("id") String id) {
        UserModel user = getAuthenticatedUser();
        if (user == null) {
            return unauthorized();
        }

        List<String> ids = new ArrayList<>(user.getAttributeStream(ATTR_PAT_ID).toList());
        int index = ids.indexOf(id);
        if (index == -1) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(Map.of("error", "Token not found"))
                    .build();
        }

        removeAttributeAtIndex(user, ATTR_PAT_ID, index);
        removeAttributeAtIndex(user, ATTR_PAT_NAME, index);
        removeAttributeAtIndex(user, ATTR_PAT_HASH, index);
        removeAttributeAtIndex(user, ATTR_PAT_SCOPES, index);
        removeAttributeAtIndex(user, ATTR_PAT_CREATED_AT, index);
        removeAttributeAtIndex(user, ATTR_PAT_EXPIRES_AT, index);
        removeAttributeAtIndex(user, ATTR_PAT_LAST_USED_AT, index);

        LOGGER.info("PAT deleted for user " + user.getUsername() + " id=" + id);

        return Response.ok(Map.of("message", "Token deleted")).build();
    }

    @POST
    @Path("/tokens/exchange")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response exchangeToken(ExchangeTokenRequest request) {
        if (request == null || request.token == null || request.token.isBlank()) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Token is required"))
                    .build();
        }

        if (!request.token.startsWith("pat_")) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "Invalid token format"))
                    .build();
        }

        try {
            String hash = sha256Hex(request.token);
            RealmModel realm = session.getContext().getRealm();

            // Find user by PAT hash
            UserModel user = findUserByPatHash(realm, hash);
            if (user == null) {
                return Response.status(Response.Status.UNAUTHORIZED)
                        .entity(Map.of("error", "Invalid token"))
                        .build();
            }

            // Find the PAT index and check expiration
            List<String> hashes = user.getAttributeStream(ATTR_PAT_HASH).toList();
            int index = hashes.indexOf(hash);
            if (index == -1) {
                return Response.status(Response.Status.UNAUTHORIZED)
                        .entity(Map.of("error", "Invalid token"))
                        .build();
            }

            List<String> expiresAts = user.getAttributeStream(ATTR_PAT_EXPIRES_AT).toList();
            if (index < expiresAts.size()) {
                String expiresAt = expiresAts.get(index);
                if (!"never".equals(expiresAt)) {
                    Instant expiry = Instant.parse(expiresAt);
                    if (Instant.now().isAfter(expiry)) {
                        return Response.status(Response.Status.UNAUTHORIZED)
                                .entity(Map.of("error", "Token expired"))
                                .build();
                    }
                }
            }

            // Update last_used_at
            updateAttributeAtIndex(user, ATTR_PAT_LAST_USED_AT, index, Instant.now().toString());

            // Issue a real Keycloak access token
            String clientId = PatResourceProviderFactory.getPatClientId();
            ClientModel client = realm.getClientByClientId(clientId);
            if (client == null) {
                LOGGER.severe(clientId + " client not found in realm " + realm.getName());
                return Response.status(Response.Status.INTERNAL_SERVER_ERROR)
                        .entity(Map.of("error", "Configuration error"))
                        .build();
            }

            // Set client in Keycloak context (required for TokenManager)
            session.getContext().setClient(client);

            // Create user session (must be persistent for introspection to work)
            UserSessionModel userSession = session.sessions().createUserSession(
                    null, realm, user, user.getUsername(),
                    "127.0.0.1", "pat-exchange", false, null, null,
                    UserSessionModel.SessionPersistenceState.PERSISTENT);

            // Create client session
            AuthenticatedClientSessionModel clientSession =
                    session.sessions().createClientSession(realm, client, userSession);
            clientSession.setNote(OIDCLoginProtocol.ISSUER,
                    Urls.realmIssuer(session.getContext().getUri().getBaseUri(), realm.getName()));

            // Build access token
            TokenManager tokenManager = new TokenManager();
            EventBuilder event = new EventBuilder(realm, session, session.getContext().getConnection())
                    .event(EventType.TOKEN_EXCHANGE);

            var clientSessionCtx = DefaultClientSessionContext
                    .fromClientSessionScopeParameter(clientSession, session);

            TokenManager.AccessTokenResponseBuilder responseBuilder =
                    tokenManager.responseBuilder(realm, client, event, session, userSession, clientSessionCtx);
            responseBuilder.generateAccessToken();

            var tokenResponse = responseBuilder.build();

            LOGGER.info("PAT exchanged for user " + user.getUsername());

            Map<String, Object> result = new LinkedHashMap<>();
            result.put("access_token", tokenResponse.getToken());
            result.put("expires_in", tokenResponse.getExpiresIn());
            result.put("token_type", "Bearer");

            return Response.ok(result).build();

        } catch (Exception e) {
            LOGGER.log(Level.WARNING, "PAT exchange failed", e);
            return Response.status(Response.Status.INTERNAL_SERVER_ERROR)
                    .entity(Map.of("error", "Exchange failed"))
                    .build();
        }
    }

    // --- Helper methods ---

    private UserModel getAuthenticatedUser() {
        if (auth == null) return null;
        return auth.getUser();
    }

    private Response unauthorized() {
        return Response.status(Response.Status.UNAUTHORIZED)
                .entity(Map.of("error", "Authentication required"))
                .build();
    }

    private UserModel findUserByPatHash(RealmModel realm, String hash) {
        Stream<UserModel> users = session.users()
                .searchForUserByUserAttributeStream(realm, ATTR_PAT_HASH, hash);
        return users.findFirst().orElse(null);
    }

    private String generateToken() {
        byte[] bytes = new byte[32];
        new SecureRandom().nextBytes(bytes);
        return "pat_" + base62Encode(bytes);
    }

    private String base62Encode(byte[] bytes) {
        BigInteger value = new BigInteger(1, bytes);
        StringBuilder sb = new StringBuilder();
        BigInteger base = BigInteger.valueOf(62);
        while (value.compareTo(BigInteger.ZERO) > 0) {
            BigInteger[] divmod = value.divideAndRemainder(base);
            sb.append(BASE62.charAt(divmod[1].intValue()));
            value = divmod[0];
        }
        return sb.reverse().toString();
    }

    private String sha256Hex(String input) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] digest = md.digest(input.getBytes("UTF-8"));
        StringBuilder sb = new StringBuilder();
        for (byte b : digest) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
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

    private void updateAttributeAtIndex(UserModel user, String attrName, int index, String value) {
        List<String> values = new ArrayList<>(user.getAttributeStream(attrName).toList());
        if (index < values.size()) {
            values.set(index, value);
            user.setAttribute(attrName, values);
        }
    }

    // --- Request classes ---

    public static class CreateTokenRequest {
        public String name;
        public String scopes;
        public Integer expiresInDays;
    }

    public static class ExchangeTokenRequest {
        public String token;
    }
}
