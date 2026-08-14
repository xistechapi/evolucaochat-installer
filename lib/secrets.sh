#!/usr/bin/env bash
set -Eeuo pipefail

: "${INSTALL_ROOT:=/opt/evolucaochat}"
: "${ENV_FILE:=$INSTALL_ROOT/.env}"
: "${VERSIONS_FILE:=$INSTALL_ROOT/versions.env}"
: "${SECRETS_DIR:=$INSTALL_ROOT/secrets}"
: "${CREDENTIALS_FILE:=$INSTALL_ROOT/credentials.txt}"

secrets_error() {
  local message="$1"
  printf '%s\n' "$message" >&2
  die 50 "$message"
}

existing_env_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

hex_secret() {
  local bytes="$1"
  openssl rand -hex "$bytes"
}

base64_secret() {
  local bytes="$1"
  openssl rand -base64 "$bytes" | tr -d '\r\n'
}

escape_compose_env_value() {
  printf '%s' "$1" | sed 's/\$/$$/g'
}

preserved_or_generated() {
  local key="$1"
  local generator="$2"
  local size="$3"
  local value
  value="$(existing_env_value "$key")"
  if [[ -z "$value" ]]; then
    value="$($generator "$size")"
  fi
  printf '%s' "$value"
}

portainer_password() {
  local value temp_password
  if [[ -s "$SECRETS_DIR/portainer_admin_password" ]]; then
    value="$(tr -d '\r\n' < "$SECRETS_DIR/portainer_admin_password")"
  else
    value="${PORTAINER_ADMIN_PASSWORD:-}"
    [[ -n "$value" ]] || secrets_error 'senha do Portainer obrigatoria'
    register_secret "$value"
    temp_password="$(mktemp "$SECRETS_DIR/.portainer-password.XXXXXX")"
    printf '%s\n' "$value" > "$temp_password"
    chmod 600 "$temp_password"
    mv -f "$temp_password" "$SECRETS_DIR/portainer_admin_password"
  fi
  printf '%s' "$value"
}

register_environment_secrets() {
  local key value
  for key in \
    POSTGRES_PASSWORD REDIS_PASSWORD CHATWOOT_SECRET_KEY_BASE \
    CHATWOOT_PLATFORM_TOKEN EVOLUTION_API_KEY EVOLUTION_LABEL_WEBHOOK_SECRET \
    JWT_SECRET CREDENTIALS_ENCRYPTION_KEY AGENT_RUNTIME_WEBHOOK_SECRET \
    MCP_APPROVAL_SIGNING_KEY; do
    value="$(existing_env_value "$key")"
    register_secret "$value"
  done
  if [[ -s "$SECRETS_DIR/portainer_admin_password" ]]; then
    value="$(tr -d '\r\n' < "$SECRETS_DIR/portainer_admin_password")"
    register_secret "$value"
  fi
}

generate_environment() {
  local postgres_password redis_password chatwoot_secret evolution_key
  local evolution_webhook jwt_secret credentials_key runtime_webhook mcp_signing
  local platform_token portainer_admin buyer_email acme_email temp_env temp_credentials

  [[ -s "$VERSIONS_FILE" ]] || secrets_error 'versions.env ausente; extraia o pacote de deployment primeiro'
  [[ -n "${RELEASE_VERSION:-}" ]] || secrets_error 'versao do release ausente'

  mkdir -p "$INSTALL_ROOT" "$SECRETS_DIR"
  chmod 700 "$INSTALL_ROOT" "$SECRETS_DIR"

  postgres_password="$(preserved_or_generated POSTGRES_PASSWORD hex_secret 32)"
  redis_password="$(preserved_or_generated REDIS_PASSWORD hex_secret 32)"
  chatwoot_secret="$(preserved_or_generated CHATWOOT_SECRET_KEY_BASE hex_secret 64)"
  evolution_key="$(preserved_or_generated EVOLUTION_API_KEY hex_secret 32)"
  evolution_webhook="$(preserved_or_generated EVOLUTION_LABEL_WEBHOOK_SECRET hex_secret 32)"
  jwt_secret="$(preserved_or_generated JWT_SECRET hex_secret 32)"
  credentials_key="$(preserved_or_generated CREDENTIALS_ENCRYPTION_KEY base64_secret 32)"
  runtime_webhook="$(preserved_or_generated AGENT_RUNTIME_WEBHOOK_SECRET hex_secret 32)"
  mcp_signing="$(preserved_or_generated MCP_APPROVAL_SIGNING_KEY hex_secret 32)"
  platform_token="$(existing_env_value CHATWOOT_PLATFORM_TOKEN)"
  portainer_admin="$(portainer_password)"
  buyer_email="$(escape_compose_env_value "$BUYER_EMAIL")"
  acme_email="$(escape_compose_env_value "$ACME_EMAIL")"
  register_secret \
    "$postgres_password" "$redis_password" "$chatwoot_secret" "$evolution_key" \
    "$evolution_webhook" "$jwt_secret" "$credentials_key" "$runtime_webhook" \
    "$mcp_signing" "$platform_token" "$portainer_admin"

  temp_env="$(mktemp "$INSTALL_ROOT/.env.XXXXXX")"
  cat > "$temp_env" <<EOF
DOMAIN_APP=$DOMAIN_APP
DOMAIN_API=$DOMAIN_API
DOMAIN_PORTAINER=$DOMAIN_PORTAINER
ACME_EMAIL=$acme_email
BUYER_EMAIL=$buyer_email
POSTGRES_USER=evolucaochat
POSTGRES_PASSWORD=$postgres_password
POSTGRES_DB=evolucaochat
REDIS_PASSWORD=$redis_password
CHATWOOT_SECRET_KEY_BASE=$chatwoot_secret
CHATWOOT_FRONTEND_URL=https://$DOMAIN_API
CHATWOOT_PLATFORM_TOKEN=$platform_token
CHATWOOT_SAFE_FETCH_ALLOW_PRIVATE_NETWORK=false
CHATWOOT_MEDIA_ALLOWED_HOSTS=chatwoot-rails
CHATWOOT_MEDIA_MAX_BYTES=26214400
CHATWOOT_MEDIA_TIMEOUT_MS=15000
EVOLUTION_API_KEY=$evolution_key
EVOLUTION_SERVER_URL=http://evolution:8080
EVOLUTION_LABEL_WEBHOOK_URL=https://$DOMAIN_API/api/webhooks/evolution/labels
EVOLUTION_LABEL_WEBHOOK_SECRET=$evolution_webhook
JWT_SECRET=$jwt_secret
CREDENTIALS_ENCRYPTION_KEY=$credentials_key
META_GRAPH_VERSION=v22.0
META_GRAPH_TIMEOUT_MS=10000
META_GRAPH_PAGINATION_TIMEOUT_MS=15000
CHATWOOT_REQUEST_TIMEOUT_MS=10000
CHATWOOT_MESSAGE_LOOKUP_TIMEOUT_MS=10000
CHATWOOT_MESSAGE_LOOKUP_MAX_PAGES=100
STORAGE_DRIVER=local
KNOWLEDGE_STORAGE_PATH=/app/data/knowledge
KNOWLEDGE_MAX_FILE_BYTES=26214400
KNOWLEDGE_MAX_TEXT_BYTES=5242880
KNOWLEDGE_FETCH_MAX_BODY_BYTES=5242880
KNOWLEDGE_MAX_EXTRACTED_CHARS=10485760
KNOWLEDGE_MAX_PDF_PAGES=500
KNOWLEDGE_MAX_CSV_ROWS=100000
KNOWLEDGE_MAX_CSV_COLUMNS=256
KNOWLEDGE_MAX_CSV_CELL_CHARS=1048576
KNOWLEDGE_MAX_ZIP_ENTRIES=10000
KNOWLEDGE_MAX_ZIP_UNCOMPRESSED_BYTES=104857600
KNOWLEDGE_MAX_ZIP_COMPRESSION_RATIO=1000
KNOWLEDGE_INSPECTION_TIMEOUT_MS=3000
KNOWLEDGE_EXTRACTION_TIMEOUT_MS=15000
KNOWLEDGE_STORAGE_TIMEOUT_MS=15000
KNOWLEDGE_FETCH_TIMEOUT_MS=15000
KNOWLEDGE_FETCH_MAX_REDIRECTS=3
KNOWLEDGE_WORKER_MEMORY_MB=128
STORAGE_CLEANUP_RECONCILE_MS=60000
STORAGE_CLEANUP_PROCESSING_STALE_MS=300000
STORAGE_UPLOAD_INTENT_STALE_MS=900000
KNOWLEDGE_INGESTION_PROCESSING_LEASE_MS=300000
KNOWLEDGE_INGESTION_RECONCILE_MS=60000
AI_REQUEST_TIMEOUT_MS=30000
AGENT_RUNTIME_ENABLED=true
AGENT_RUNTIME_WEBHOOK_SECRET=$runtime_webhook
AGENT_RUNTIME_CHATWOOT_WEBHOOK_URL=http://api:3001/api/agent-runtime/chatwoot/webhook
AGENT_RUNTIME_WEBHOOK_SIGNATURE_TOLERANCE_SECONDS=300
AGENT_RUNTIME_WEBHOOK_RATE_LIMIT_MAX=120
AGENT_RUNTIME_WEBHOOK_RATE_LIMIT_WINDOW_MS=60000
AGENT_RUNTIME_WEBHOOK_RATE_LIMIT_MAX_KEYS=1000
MCP_APPROVAL_SIGNING_KEY=$mcp_signing
MCP_OAUTH_REDIRECT_URI=https://$DOMAIN_API/api/mcp/oauth/callback
MCP_OAUTH_PANEL_BASE_URL=https://$DOMAIN_APP
MCP_OAUTH_TIMEOUT_MS=20000
MCP_EXECUTION_RECONCILE_MS=60000
MCP_ALLOWED_PORTS=
S3_BUCKET=
S3_REGION=
S3_ENDPOINT=
S3_FORCE_PATH_STYLE=false
S3_ACCESS_KEY_ID=
S3_SECRET_ACCESS_KEY=
S3_SESSION_TOKEN=
S3_SHARED_CREDENTIALS_FILE=
S3_AWS_PROFILE=
VITE_API_URL=https://$DOMAIN_API/api
EVOLUCAOCHAT_API_IMAGE=evolucaochat-api:$RELEASE_VERSION
EVOLUCAOCHAT_PANEL_IMAGE=evolucaochat-painel:$RELEASE_VERSION
PORTAINER_ADMIN_PASSWORD_FILE=$SECRETS_DIR/portainer_admin_password
EOF
  chmod 600 "$temp_env"
  mv -f "$temp_env" "$ENV_FILE"
  chmod 600 "$ENV_FILE" "$VERSIONS_FILE"

  temp_credentials="$(mktemp "$INSTALL_ROOT/.credentials.XXXXXX")"
  cat > "$temp_credentials" <<EOF
Painel: https://$DOMAIN_APP
API: https://$DOMAIN_API
Portainer: https://$DOMAIN_PORTAINER
Usuario do Portainer: admin
Senha do Portainer: $portainer_admin
EOF
  chmod 600 "$temp_credentials"
  mv -f "$temp_credentials" "$CREDENTIALS_FILE"
  register_environment_secrets
  log "ambiente gerado; credenciais protegidas em $CREDENTIALS_FILE"
}
