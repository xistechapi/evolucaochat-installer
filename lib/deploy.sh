#!/usr/bin/env bash
set -Eeuo pipefail

: "${INSTALL_ROOT:=/opt/evolucaochat}"
: "${CACHE_DIR:=$INSTALL_ROOT/cache}"
: "${ENV_FILE:=$INSTALL_ROOT/.env}"
: "${VERSIONS_FILE:=$INSTALL_ROOT/versions.env}"
: "${CHATWOOT_BOOTSTRAP_SCRIPT:=$INSTALL_ROOT/bootstrap-chatwoot.sh}"
: "${DEPLOY_WAIT_ATTEMPTS:=36}"
: "${DEPLOY_WAIT_INTERVAL:=5}"

deploy_error() {
  local message="$1"
  printf '%s\n' "$message" >&2
  die 60 "$message"
}

prepare_deployment_files() {
  local bundle="$CACHE_DIR/evolucaochat-deployment.tar.zst"
  local staging listing file
  local expected=$'.env.example\napp.compose.yml\nbootstrap-chatwoot.sh\ninfra.compose.yml\npostgres/init-databases.sh\nversions.env'
  [[ -s "$bundle" ]] || deploy_error 'pacote de deployment verificado ausente'

  mkdir -p "$INSTALL_ROOT"
  staging="$(mktemp -d "$INSTALL_ROOT/.deployment.XXXXXX")"
  listing="$staging/.entries"
  zstd -dc "$bundle" | tar -tf - | sort > "$listing"
  if [[ "$(cat "$listing")" != "$expected" ]]; then
    rm -rf -- "$staging"
    deploy_error 'pacote de deployment contem caminhos inesperados'
  fi
  zstd -dc "$bundle" | tar -xf - -C "$staging"
  for file in .env.example app.compose.yml bootstrap-chatwoot.sh infra.compose.yml postgres/init-databases.sh versions.env; do
    [[ -f "$staging/$file" && ! -L "$staging/$file" ]] || {
      rm -rf -- "$staging"
      deploy_error "arquivo inseguro no pacote de deployment: $file"
    }
  done

  mkdir -p "$INSTALL_ROOT/postgres"
  cp -- "$staging/infra.compose.yml" "$INSTALL_ROOT/infra.compose.yml"
  cp -- "$staging/app.compose.yml" "$INSTALL_ROOT/app.compose.yml"
  cp -- "$staging/versions.env" "$VERSIONS_FILE"
  cp -- "$staging/.env.example" "$INSTALL_ROOT/.env.example"
  cp -- "$staging/bootstrap-chatwoot.sh" "$INSTALL_ROOT/bootstrap-chatwoot.sh"
  cp -- "$staging/postgres/init-databases.sh" "$INSTALL_ROOT/postgres/init-databases.sh"
  chmod 600 "$INSTALL_ROOT/infra.compose.yml" "$INSTALL_ROOT/app.compose.yml" "$VERSIONS_FILE" "$INSTALL_ROOT/.env.example"
  chmod 700 "$INSTALL_ROOT/bootstrap-chatwoot.sh"
  chmod 755 "$INSTALL_ROOT/postgres/init-databases.sh"
  rm -rf -- "$staging"
}

load_release_images() {
  local bundle="$CACHE_DIR/evolucaochat-images.tar.zst"
  [[ -s "$bundle" ]] || deploy_error 'pacote de imagens verificado ausente'
  zstd -dc "$bundle" | docker load >/dev/null
  docker image inspect "evolucaochat-api:$RELEASE_VERSION" >/dev/null 2>&1 || deploy_error 'imagem da API ausente apos o carregamento'
  docker image inspect "evolucaochat-painel:$RELEASE_VERSION" >/dev/null 2>&1 || deploy_error 'imagem do painel ausente apos o carregamento'
}

release_images_available() {
  docker image inspect "evolucaochat-api:$RELEASE_VERSION" >/dev/null 2>&1 &&
    docker image inspect "evolucaochat-painel:$RELEASE_VERSION" >/dev/null 2>&1
}

compose_file() {
  local compose_name="$1"
  shift
  docker compose \
    --env-file "$VERSIONS_FILE" \
    --env-file "$ENV_FILE" \
    -f "$INSTALL_ROOT/$compose_name" \
    "$@"
}

wait_for_url() {
  local url="$1"
  local label="$2"
  local attempt
  for (( attempt=1; attempt<=DEPLOY_WAIT_ATTEMPTS; attempt++ )); do
    if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$DEPLOY_WAIT_INTERVAL"
  done
  deploy_error "$label nao respondeu com TLS valido dentro do prazo"
}

deploy_infrastructure() {
  compose_file infra.compose.yml up -d
  wait_for_url "https://$DOMAIN_PORTAINER" 'Portainer'
}

write_platform_token() {
  local token="$1"
  local temp_env found=0 line
  temp_env="$(mktemp "$INSTALL_ROOT/.env-platform-token.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == CHATWOOT_PLATFORM_TOKEN=* ]]; then
      printf 'CHATWOOT_PLATFORM_TOKEN=%s\n' "$token" >> "$temp_env"
      found=1
    else
      printf '%s\n' "$line" >> "$temp_env"
    fi
  done < "$ENV_FILE"
  (( found == 1 )) || printf 'CHATWOOT_PLATFORM_TOKEN=%s\n' "$token" >> "$temp_env"
  chmod 600 "$temp_env"
  mv -f "$temp_env" "$ENV_FILE"
}

bootstrap_chatwoot() {
  local token attempt
  token="$(sed -n 's/^CHATWOOT_PLATFORM_TOKEN=//p' "$ENV_FILE" | tail -n 1)"
  if [[ -n "$token" ]]; then
    register_secret "$token"
    return 0
  fi

  [[ -x "$CHATWOOT_BOOTSTRAP_SCRIPT" ]] || deploy_error 'script de bootstrap do Chatwoot ausente'
  for (( attempt=1; attempt<=DEPLOY_WAIT_ATTEMPTS; attempt++ )); do
    token="$($CHATWOOT_BOOTSTRAP_SCRIPT 2>/dev/null || true)"
    token="$(printf '%s' "$token" | tail -n 1 | tr -d '\r\n')"
    if [[ "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
      register_secret "$token"
      write_platform_token "$token"
      log 'token de plataforma do Chatwoot persistido com seguranca'
      return 0
    fi
    sleep "$DEPLOY_WAIT_INTERVAL"
  done
  deploy_error 'bootstrap do Chatwoot nao retornou token valido dentro do prazo'
}

deploy_application() {
  compose_file app.compose.yml up -d postgres redis chatwoot-rails
  bootstrap_chatwoot
  compose_file app.compose.yml up -d api painel evolution chatwoot-sidekiq
  wait_for_url "https://$DOMAIN_APP" 'Painel'
  wait_for_url "https://$DOMAIN_API/api" 'API'
}

verify_deployment() {
  compose_file infra.compose.yml ps
  compose_file app.compose.yml ps
  wait_for_url "https://$DOMAIN_PORTAINER" 'Portainer'
  wait_for_url "https://$DOMAIN_APP" 'Painel'
  wait_for_url "https://$DOMAIN_API/api" 'API'
}
