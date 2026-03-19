# Keycloak Configuration Migrations

**keycloak-config-cli** is the single source of truth for the `x509-demo` realm. All realm configuration — from initial provisioning to incremental changes — is managed through versioned YAML files in `config-cli/`.

A plain `docker compose up` provisions a fresh Keycloak instance end-to-end: no `--import-realm`, no manual steps.

## Why config-cli over `--import-realm`

Keycloak's built-in `--import-realm` is fire-and-forget; config-cli is convergent:

| | `--import-realm` | `keycloak-config-cli` |
|---|---|---|
| **Existing realm** | Silently skips — does nothing | Merges/updates to match desired state |
| **Changed config** | Must wipe DB to re-apply | Just re-run — patches the diff |
| **Add a client** | Edit monolithic JSON, wipe, reimport | Add a YAML file, re-run |
| **Env-specific values** | Hardcoded in JSON | `$(env:REALM_NAME:-default)` |
| **Day-2 operations** | Useless — only works on empty DB | Works anytime on a running instance |

In short: `--import-realm` is a seed mechanism for first boot. Config-cli is a configuration management tool that works across the full lifecycle.

## Pipeline

Files are processed in alphabetical order. Each migration is idempotent.

| File | Purpose |
|------|---------|
| `000_baseline.yaml` | Full realm baseline: settings, roles, users, clients, attributes, events |
| `001_x509-authentication-flow.yaml` | X.509 authentication flows, authenticator configs, browser flow binding |
| `002_x509-client-mappers.yaml` | Additional protocol mappers on `x509-demo-app` |

## Directory Structure

```
keycloak/migrations/
├── README.md
├── docker-compose.migrations.yaml   # Watch mode override (development)
└── config-cli/                      # YAML migrations (source of truth)
    ├── 000_baseline.yaml
    ├── 001_x509-authentication-flow.yaml
    └── 002_x509-client-mappers.yaml
```

## Usage

### Fresh provisioning

```bash
# Wipe state and start fresh
docker compose down -v
docker compose up -d
```

Keycloak starts empty. The `keycloak-config-cli` service (defined in `docker-compose.yml`) waits for Keycloak to become healthy, then applies all YAML files in order.

### Run migrations on an existing instance

```bash
# Re-run config-cli (idempotent — safe to repeat)
docker compose up keycloak-config-cli
```

### Development watch mode

Re-applies config every 10 seconds (picks up file changes):

```bash
docker compose -f docker-compose.yml -f keycloak/migrations/docker-compose.migrations.yaml \
    run --rm keycloak-config-cli-watch
```

### Custom realm / client

```bash
REALM_NAME=my-realm CLIENT_ID=my-app docker compose up keycloak-config-cli
```

## Adding a new migration

1. Create `config-cli/NNN_description.yaml` with the next sequence number
2. Set `realm: "$(env:REALM_NAME:-x509-demo)"` at the top
3. Define only the resources that change (config-cli merges by name)
4. Test: `docker compose up keycloak-config-cli`

## Rollback

keycloak-config-cli is idempotent but does not support automatic rollback. Options:

1. **Create a rollback config file** that reverts changes
2. **Restore from backup** (recommended for production)
3. **Wipe and re-provision** for development: `docker compose down -v && docker compose up -d`

## CI/CD Integration

### GitHub Actions

```yaml
name: Keycloak Migrations

on:
  push:
    branches: [main]
    paths:
      - 'keycloak/keycloak/migrations/config-cli/**'

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run migrations
        run: |
          docker run --rm \
            -e KEYCLOAK_URL=${{ secrets.KEYCLOAK_URL }} \
            -e KEYCLOAK_USER=${{ secrets.KEYCLOAK_ADMIN }} \
            -e KEYCLOAK_PASSWORD=${{ secrets.KEYCLOAK_PASSWORD }} \
            -e REALM_NAME=production \
            -v ${{ github.workspace }}/keycloak/keycloak/migrations/config-cli:/config \
            adorsys/keycloak-config-cli:6.5.0-24
```

## Alternative approaches

For reference, `terraform/` and `scripts/` directories contain alternative migration approaches (Terraform provider and custom Flyway-style scripts). These are not used in the default workflow but may be useful for organizations with different tooling preferences.

## Troubleshooting

### Check config-cli logs

```bash
docker compose logs keycloak-config-cli
```

### Check Keycloak logs

```bash
docker logs keycloak 2>&1 | grep -i "error\|warn"
```

### Verify realm was created

```bash
curl -s "http://localhost:8080/admin/realms" \
    -H "Authorization: Bearer $TOKEN" | jq '.[].realm'
```

### Reset to known state

```bash
docker compose down -v
docker compose up -d
```
