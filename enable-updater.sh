#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${ENABLE_UPDATER_TEST_MODE:-}" != 1 ]]; then
  INSTALL_ROOT=/opt/evolucaochat
fi
: "${INSTALL_ROOT:=/opt/evolucaochat}"
: "${RELEASE_PUBLIC_KEY_SOURCE:=$INSTALLER_DIR/keys/release-public.pem}"
RELEASE_PUBLIC_KEY="$RELEASE_PUBLIC_KEY_SOURCE"
LOG_FILE="$INSTALL_ROOT/updater-enable.log"
source "$INSTALLER_DIR/lib/common.sh"
source "$INSTALLER_DIR/lib/license.sh"
source "$INSTALLER_DIR/lib/deploy.sh"

release_dir=''
backup_dir=''
staging=''
prior_api_id=''
prior_panel_id=''
prior_helper_image_id=''
installed_version=''
existing_updater_secret=''
existing_updater_image=''
updater_secret=''
mutation_started=0
api_recreated=0
helper_start_attempted=0
prior_helper_state=absent
activated=0

enable_error() {
  printf 'ERRO: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Uso: %s --release-dir /caminho/release-assinado --backup-dir /caminho/backup-novo\n' "$0" >&2
  exit 2
}

cleanup() {
  local result=$? restore_files_ok=1 restore_api_tag_ok=1 restore_helper_tag_ok=1 recovery_errors=0
  trap - EXIT
  set +e
  if (( mutation_started == 1 && activated == 0 )); then
    if (( helper_start_attempted == 1 )) && [[ "$prior_helper_state" == absent ]]; then
      if ! compose_file app.compose.yml stop evolucaochat-updater >/dev/null 2>&1; then
        printf 'ERRO: parada do atualizador novo falhou; backup em %s\n' "$backup_dir" >&2
        recovery_errors=$((recovery_errors + 1))
      fi
    fi
    if ! cp -- "$backup_dir/.env" "$INSTALL_ROOT/.env" >/dev/null 2>&1; then
      printf 'ERRO: restauracao de .env falhou; backup em %s\n' "$backup_dir" >&2
      restore_files_ok=0
      recovery_errors=$((recovery_errors + 1))
    fi
    if ! cp -- "$backup_dir/app.compose.yml" "$INSTALL_ROOT/app.compose.yml" >/dev/null 2>&1; then
      printf 'ERRO: restauracao de app.compose.yml falhou; backup em %s\n' "$backup_dir" >&2
      restore_files_ok=0
      recovery_errors=$((recovery_errors + 1))
    fi
    if ! chmod 600 "$INSTALL_ROOT/.env" "$INSTALL_ROOT/app.compose.yml" >/dev/null 2>&1; then
      printf 'ERRO: permissoes dos arquivos restaurados falharam; backup em %s\n' "$backup_dir" >&2
      restore_files_ok=0
      recovery_errors=$((recovery_errors + 1))
    fi
    if ! docker tag "$prior_api_id" "evolucaochat-api:$installed_version" >/dev/null 2>&1; then
      printf 'ERRO: retag da API falhou; backup em %s\n' "$backup_dir" >&2
      restore_api_tag_ok=0
      recovery_errors=$((recovery_errors + 1))
    fi
    if ! docker tag "$prior_panel_id" "evolucaochat-painel:$installed_version" >/dev/null 2>&1; then
      printf 'ERRO: retag do painel falhou; backup em %s\n' "$backup_dir" >&2
      recovery_errors=$((recovery_errors + 1))
    fi
    if [[ "$prior_helper_state" == healthy ]] &&
      ! docker tag "$prior_helper_image_id" "evolucaochat-updater:$installed_version" >/dev/null 2>&1; then
      printf 'ERRO: retag do atualizador anterior falhou; backup em %s\n' "$backup_dir" >&2
      restore_helper_tag_ok=0
      recovery_errors=$((recovery_errors + 1))
    fi
    if (( helper_start_attempted == 1 )) && [[ "$prior_helper_state" == healthy ]]; then
      if (( restore_files_ok == 0 || restore_helper_tag_ok == 0 )); then
        printf 'ERRO: atualizador anterior nao pode ser restaurado com seguranca; backup em %s\n' "$backup_dir" >&2
        recovery_errors=$((recovery_errors + 1))
      elif ! compose_file app.compose.yml up -d --no-deps --no-build --pull never --force-recreate evolucaochat-updater >/dev/null 2>&1 ||
        ! wait_for_recovered_helper; then
        printf 'ERRO: restauracao do atualizador anterior falhou; backup em %s\n' "$backup_dir" >&2
        recovery_errors=$((recovery_errors + 1))
      fi
    fi
    if (( api_recreated == 1 )); then
      if (( restore_files_ok == 0 || restore_api_tag_ok == 0 )); then
        printf 'ERRO: API anterior nao pode ser recriada com seguranca; backup em %s\n' "$backup_dir" >&2
        recovery_errors=$((recovery_errors + 1))
      elif ! compose_file app.compose.yml up -d --no-deps --no-build --pull never --force-recreate api >/dev/null 2>&1 ||
        ! wait_for_api_runtime "$existing_updater_secret"; then
        printf 'ERRO: recuperacao da API falhou; backup em %s\n' "$backup_dir" >&2
        recovery_errors=$((recovery_errors + 1))
      fi
    fi
    if (( recovery_errors > 0 )); then
      printf 'ERRO: recuperacao incompleta; intervencao manual necessaria; backup em %s\n' "$backup_dir" >&2
    fi
  fi
  if [[ -n "$staging" ]] && ! rm -rf -- "$staging"; then
    printf 'ERRO: limpeza temporaria falhou em %s\n' "$staging" >&2
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --release-dir) (( $# >= 2 )) || usage; release_dir="$2"; shift 2 ;;
      --backup-dir) (( $# >= 2 )) || usage; backup_dir="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$release_dir" == /* && -d "$release_dir" && ! -L "$release_dir" ]] || usage
  [[ "$backup_dir" == /* && ! -e "$backup_dir" && ! -L "$backup_dir" ]] || usage
  [[ -d "$(dirname "$backup_dir")" && ! -L "$(dirname "$backup_dir")" ]] || usage
}

require_known_installation() {
  [[ "$(id -u)" == 0 ]] || enable_error 'execute como root'
  [[ -d "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] || enable_error 'instalacao conhecida em /opt/evolucaochat ausente'
  docker_storage_root="$(local_docker_storage_root)" || enable_error 'armazenamento do Docker local nao pode ser identificado com seguranca'
  local prior_storage_root storage_count
  storage_count="$(grep -c '^SYSTEM_UPDATER_DOCKER_ROOT=' "$INSTALL_ROOT/.env" || true)"
  [[ "$storage_count" -le 1 ]] || enable_error 'configuracao de armazenamento duplicada'
  prior_storage_root="$(sed -n 's/^SYSTEM_UPDATER_DOCKER_ROOT=//p' "$INSTALL_ROOT/.env")"
  [[ -z "$prior_storage_root" || "$prior_storage_root" == "$docker_storage_root" ]] || enable_error 'armazenamento do Docker mudou; baseline assistido necessario'
  containerd_storage_root="$(local_containerd_storage_root)" || enable_error 'armazenamento do containerd local requer configuracao assistida'
  storage_count="$(grep -c '^SYSTEM_UPDATER_CONTAINERD_ROOT=' "$INSTALL_ROOT/.env" || true)"
  [[ "$storage_count" -le 1 ]] || enable_error 'configuracao de armazenamento containerd duplicada'
  prior_storage_root="$(sed -n 's/^SYSTEM_UPDATER_CONTAINERD_ROOT=//p' "$INSTALL_ROOT/.env")"
  [[ -z "$prior_storage_root" || "$prior_storage_root" == "$containerd_storage_root" ]] || enable_error 'armazenamento do containerd mudou; baseline assistido necessario'
  local file
  for file in .env versions.env app.compose.yml cache/manifest.json installation-id infra.compose.yml .env.example bootstrap-chatwoot.sh postgres/init-databases.sh; do
    [[ -s "$INSTALL_ROOT/$file" && ! -L "$INSTALL_ROOT/$file" ]] || enable_error "instalacao conhecida incompleta: $file"
  done
  [[ -f "$RELEASE_PUBLIC_KEY_SOURCE" && ! -L "$RELEASE_PUBLIC_KEY_SOURCE" ]] || enable_error 'chave publica confiavel ausente'
  installed_version="$(jq -r '.releaseVersion // empty' "$INSTALL_ROOT/cache/manifest.json")"
  [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || enable_error 'versao instalada invalida'
  grep -Fxq "EVOLUCAOCHAT_API_IMAGE=evolucaochat-api:$installed_version" "$INSTALL_ROOT/.env" || enable_error 'imagem da API instalada nao corresponde ao manifesto'
  grep -Fxq "EVOLUCAOCHAT_PANEL_IMAGE=evolucaochat-painel:$installed_version" "$INSTALL_ROOT/.env" || enable_error 'imagem do painel instalado nao corresponde ao manifesto'
}

image_metadata() {
  local tag="$1"
  docker image inspect "$tag" | jq -ec 'if type == "array" and length == 1 then .[0] else error("inspect") end'
}

require_installed_baseline() {
  local api panel migration deployment panel_deployment
  api="$(image_metadata "evolucaochat-api:$installed_version")" || enable_error 'imagem instalada da API ausente'
  panel="$(image_metadata "evolucaochat-painel:$installed_version")" || enable_error 'imagem instalada do painel ausente'
  prior_api_id="$(jq -r '.Id // empty' <<< "$api")"
  prior_panel_id="$(jq -r '.Id // empty' <<< "$panel")"
  migration="$(jq -r '.Config.Labels["com.evolucaochat.migrations-sha256"] // empty' <<< "$api")"
  deployment="$(jq -r '.Config.Labels["com.evolucaochat.deployment-sha256"] // empty' <<< "$api")"
  panel_deployment="$(jq -r '.Config.Labels["com.evolucaochat.deployment-sha256"] // empty' <<< "$panel")"
  [[ "$prior_api_id" =~ ^sha256:[0-9a-f]{64}$ && "$prior_panel_id" =~ ^sha256:[0-9a-f]{64}$ ]] || enable_error 'IDs das imagens instaladas invalidos'
  [[ "$migration" =~ ^[0-9a-f]{64}$ && "$deployment" =~ ^[0-9a-f]{64}$ && "$panel_deployment" == "$deployment" ]] ||
    enable_error 'imagens legadas sem fingerprints compativeis; faca primeiro um baseline assistido com backup e avaliacao das migrations'
}

validate_signed_payload() {
  local expected_listing=$'.env.example\napp.compose.yml\nbootstrap-chatwoot.sh\ninfra.compose.yml\npostgres/init-databases.sh\nversions.env'
  local file services
  verify_release_directory "$release_dir"
  [[ "$(jq -r '.releaseVersion' "$release_dir/manifest.json")" == "$installed_version" ]] ||
    enable_error 'release local deve ter a mesma versao instalada; upgrade de API/painel exige baseline assistido'

  staging="$(mktemp -d "$INSTALL_ROOT/.updater-activation.XXXXXX")"
  zstd -dc "$release_dir/evolucaochat-deployment.tar.zst" | tar -tf - | sort > "$staging/listing"
  [[ "$(cat "$staging/listing")" == "$expected_listing" ]] || enable_error 'deployment assinado contem caminhos inesperados'
  zstd -dc "$release_dir/evolucaochat-deployment.tar.zst" | tar -xf - -C "$staging"
  for file in .env.example app.compose.yml bootstrap-chatwoot.sh infra.compose.yml postgres/init-databases.sh versions.env; do
    [[ -f "$staging/$file" && ! -L "$staging/$file" ]] || enable_error "arquivo inseguro no deployment: $file"
  done
  for file in .env.example bootstrap-chatwoot.sh infra.compose.yml postgres/init-databases.sh versions.env; do
    cmp -s "$staging/$file" "$INSTALL_ROOT/$file" || enable_error "deployment instalado diverge do release assinado: $file"
  done
  zstd -dc "$release_dir/evolucaochat-images.tar.zst" | tar -xOf - manifest.json |
    jq -e --arg version "$installed_version" '
      type == "array" and length == 3 and
      all(.[]; (.RepoTags | type == "array" and length == 1)) and
      ([.[].RepoTags[]] | sort) == (["evolucaochat-api:" + $version, "evolucaochat-painel:" + $version, "evolucaochat-updater:" + $version] | sort)
    ' >/dev/null || enable_error 'bundle assinado nao contem exatamente as tres imagens esperadas'
  services="$(SYSTEM_UPDATER_SHARED_SECRET="$(printf '%064d' 0)" EVOLUCAOCHAT_UPDATER_IMAGE="evolucaochat-updater:$installed_version" \
    SYSTEM_UPDATER_DOCKER_ROOT="$docker_storage_root" SYSTEM_UPDATER_CONTAINERD_ROOT="$containerd_storage_root" \
    docker compose --env-file "$INSTALL_ROOT/versions.env" --env-file "$INSTALL_ROOT/.env" -f "$staging/app.compose.yml" config --services)" ||
    enable_error 'Compose assinado invalido'
  grep -Fxq evolucaochat-updater <<< "$services" || enable_error 'release assinado nao define atualizador'
}

create_backup() {
  mkdir -m 700 -- "$backup_dir"
  local file
  for file in .env versions.env app.compose.yml; do
    cp -- "$INSTALL_ROOT/$file" "$backup_dir/$file"
  done
  cp -- "$INSTALL_ROOT/cache/manifest.json" "$backup_dir/manifest.json"
  printf '%s\n%s\n' "$prior_api_id" "$prior_panel_id" > "$backup_dir/image-ids.txt"
  chmod 600 "$backup_dir"/* "$backup_dir/.env"
}

require_updater_environment() {
  local secret_count image_count
  secret_count="$(grep -c '^SYSTEM_UPDATER_SHARED_SECRET=' "$INSTALL_ROOT/.env" || true)"
  image_count="$(grep -c '^EVOLUCAOCHAT_UPDATER_IMAGE=' "$INSTALL_ROOT/.env" || true)"
  [[ "$secret_count" -le 1 && "$image_count" -le 1 ]] || enable_error 'configuracao duplicada do atualizador'
  existing_updater_secret="$(sed -n 's/^SYSTEM_UPDATER_SHARED_SECRET=//p' "$INSTALL_ROOT/.env")"
  existing_updater_image="$(sed -n 's/^EVOLUCAOCHAT_UPDATER_IMAGE=//p' "$INSTALL_ROOT/.env")"
  if (( secret_count == 1 )); then
    [[ "$existing_updater_secret" =~ ^[0-9a-f]{64}$ ]] || enable_error 'segredo existente do atualizador invalido'
  fi
  if (( image_count == 1 )); then
    [[ "$existing_updater_image" == "evolucaochat-updater:$installed_version" ]] || enable_error 'imagem existente do atualizador diverge da release'
  fi
}

capture_prior_helper() {
  local container_id status running_image tagged_image
  container_id="$(compose_file app.compose.yml ps -q evolucaochat-updater 2>/dev/null || true)"
  [[ -n "$container_id" ]] || return 0
  status="$(docker inspect --format '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
  [[ "$status" == healthy ]] || enable_error 'atualizador existente nao esta saudavel; baseline assistido necessario'
  tagged_image="$(image_metadata "evolucaochat-updater:$installed_version")" || enable_error 'imagem do atualizador existente ausente'
  prior_helper_image_id="$(jq -r '.Id // empty' <<< "$tagged_image")"
  running_image="$(docker inspect --format '{{.Image}}' "$container_id" 2>/dev/null || true)"
  [[ "$prior_helper_image_id" =~ ^sha256:[0-9a-f]{64}$ && "$running_image" == "$prior_helper_image_id" ]] ||
    enable_error 'atualizador existente usa outra imagem; baseline assistido necessario'
  prior_helper_state=healthy
}

wait_for_recovered_helper() {
  local attempt container_id status
  for (( attempt=1; attempt<=DEPLOY_WAIT_ATTEMPTS; attempt++ )); do
    container_id="$(compose_file app.compose.yml ps -q evolucaochat-updater 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      status="$(docker inspect --format '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
      [[ "$status" == healthy ]] && return 0
    fi
    sleep "$DEPLOY_WAIT_INTERVAL"
  done
  return 1
}

require_trusted_release_key() {
  local installed_key="$INSTALL_ROOT/secrets/release-public.pem"
  if [[ -e "$installed_key" || -L "$installed_key" ]]; then
    [[ -f "$installed_key" && ! -L "$installed_key" ]] || enable_error 'chave publica instalada insegura'
    cmp -s "$RELEASE_PUBLIC_KEY_SOURCE" "$installed_key" || enable_error 'chave publica instalada diverge da chave confiavel; avaliacao assistida necessaria'
  fi
}

require_same_images_after_load() {
  local api panel helper loaded_api_id loaded_panel_id loaded_helper_id migration deployment panel_deployment
  api="$(image_metadata "evolucaochat-api:$installed_version")"
  panel="$(image_metadata "evolucaochat-painel:$installed_version")"
  helper="$(image_metadata "evolucaochat-updater:$installed_version")" || enable_error 'imagem assinada do atualizador ausente apos load'
  loaded_api_id="$(jq -r '.Id // empty' <<< "$api")"
  loaded_panel_id="$(jq -r '.Id // empty' <<< "$panel")"
  loaded_helper_id="$(jq -r '.Id // empty' <<< "$helper")"
  migration="$(jq -r '.Config.Labels["com.evolucaochat.migrations-sha256"] // empty' <<< "$api")"
  deployment="$(jq -r '.Config.Labels["com.evolucaochat.deployment-sha256"] // empty' <<< "$api")"
  panel_deployment="$(jq -r '.Config.Labels["com.evolucaochat.deployment-sha256"] // empty' <<< "$panel")"
  [[ "$loaded_api_id" == "$prior_api_id" && "$loaded_panel_id" == "$prior_panel_id" &&
     "$migration" =~ ^[0-9a-f]{64}$ && "$deployment" =~ ^[0-9a-f]{64}$ && "$panel_deployment" == "$deployment" ]] ||
    enable_error 'release assinado difere das imagens instaladas; upgrade de API/painel exige baseline assistido'
  if [[ "$prior_helper_state" == healthy && "$loaded_helper_id" != "$prior_helper_image_id" ]]; then
    enable_error 'release assinado difere da imagem do atualizador ativo; restaurando tag anterior'
  fi
}

write_configuration() {
  local secret temp_env temp_compose temp_key
  secret="$existing_updater_secret"
  [[ -n "$secret" ]] || secret="$(openssl rand -hex 32)"
  updater_secret="$secret"
  register_secret "$secret"
  temp_env="$(mktemp "$INSTALL_ROOT/.env-updater.XXXXXX")"
  cp -- "$INSTALL_ROOT/.env" "$temp_env"
  [[ -n "$existing_updater_image" ]] || printf 'EVOLUCAOCHAT_UPDATER_IMAGE=evolucaochat-updater:%s\n' "$installed_version" >> "$temp_env"
  grep -q '^SYSTEM_UPDATER_SHARED_SECRET=' "$temp_env" || printf 'SYSTEM_UPDATER_SHARED_SECRET=%s\n' "$secret" >> "$temp_env"
  grep -q '^SYSTEM_UPDATER_DOCKER_ROOT=' "$temp_env" || printf 'SYSTEM_UPDATER_DOCKER_ROOT=%s\n' "$docker_storage_root" >> "$temp_env"
  grep -q '^SYSTEM_UPDATER_CONTAINERD_ROOT=' "$temp_env" || printf 'SYSTEM_UPDATER_CONTAINERD_ROOT=%s\n' "$containerd_storage_root" >> "$temp_env"
  chmod 600 "$temp_env"
  mv -f "$temp_env" "$INSTALL_ROOT/.env"

  mkdir -p "$INSTALL_ROOT/secrets"
  chmod 700 "$INSTALL_ROOT/secrets"
  temp_key="$(mktemp "$INSTALL_ROOT/secrets/.release-public.XXXXXX")"
  cp -- "$RELEASE_PUBLIC_KEY_SOURCE" "$temp_key"
  chmod 644 "$temp_key"
  mv -f "$temp_key" "$INSTALL_ROOT/secrets/release-public.pem"

  temp_compose="$(mktemp "$INSTALL_ROOT/.app-compose.XXXXXX")"
  cp -- "$staging/app.compose.yml" "$temp_compose"
  chmod 600 "$temp_compose"
  mv -f "$temp_compose" "$INSTALL_ROOT/app.compose.yml"
}

api_runtime_matches() {
  local expected_secret="$1" container_id
  container_id="$(compose_file app.compose.yml ps -q api)" || return 1
  [[ -n "$container_id" ]] || return 1
  docker inspect "$container_id" 2>/dev/null |
        jq -e --arg image "$prior_api_id" --arg secret "$expected_secret" '
          type == "array" and length == 1 and .[0].Image == $image and
          .[0].State.Running == true and .[0].State.Health.Status == "healthy" and
          .[0].Config.Labels["com.docker.compose.service"] == "api" and
          (if $secret == "" then
            ([.[0].Config.Env[]? | select(startswith("SYSTEM_UPDATER_SHARED_SECRET="))] | length == 0)
          else
            ([.[0].Config.Env[]? | select(. == "SYSTEM_UPDATER_SHARED_SECRET=" + $secret)] | length == 1)
          end)
        ' >/dev/null 2>&1
}

wait_for_api_runtime() {
  local expected_secret="$1" attempt
  for (( attempt=1; attempt<=DEPLOY_WAIT_ATTEMPTS; attempt++ )); do
    if api_runtime_matches "$expected_secret"; then return 0; fi
    sleep "$DEPLOY_WAIT_INTERVAL"
  done
  return 1
}

main() {
  parse_arguments "$@"
  require_known_installation
  require_installed_baseline
  validate_signed_payload
  require_updater_environment
  require_trusted_release_key
  api_runtime_matches "$existing_updater_secret" || enable_error 'API instalada nao esta saudavel ou usa outra imagem/configuracao; baseline assistido necessario'
  capture_prior_helper
  create_backup
  mutation_started=1
  zstd -dc "$release_dir/evolucaochat-images.tar.zst" | docker load >/dev/null
  require_same_images_after_load
  write_configuration
  helper_start_attempted=1
  compose_file app.compose.yml up -d evolucaochat-updater
  wait_for_updater_health
  api_recreated=1
  compose_file app.compose.yml up -d --no-deps --no-build --pull never --force-recreate api
  wait_for_api_runtime "$updater_secret" || enable_error 'API nao recebeu o segredo ou nao ficou saudavel'
  activated=1
  printf 'Atualizador habilitado. Backup operacional preservado em %s\n' "$backup_dir"
}

main "$@"
