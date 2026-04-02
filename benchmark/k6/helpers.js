import http from "k6/http";

const KC_URL = "http://keycloak:8080";
const REALM = "public";
const CLIENT_ID = "ui-bff";
const CLIENT_SECRET = "bff-secret";

export const NGINX_BASE = "https://nginx-proxy:443";

export function getToken(username, password) {
  const res = http.post(
    `${KC_URL}/realms/${REALM}/protocol/openid-connect/token`,
    {
      grant_type: "password",
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      username: username,
      password: password,
    },
    { headers: { "Content-Type": "application/x-www-form-urlencoded" } }
  );

  if (res.status !== 200) {
    throw new Error(`Token request failed: ${res.status} ${res.body}`);
  }

  return JSON.parse(res.body).access_token;
}

export function createPat(accessToken, name) {
  const res = http.post(
    `${KC_URL}/realms/${REALM}/pat-api/tokens`,
    JSON.stringify({ name: name, expiresInDays: 1 }),
    {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
    }
  );

  if (res.status !== 200) {
    throw new Error(`PAT creation failed: ${res.status} ${res.body}`);
  }

  return JSON.parse(res.body).token;
}
