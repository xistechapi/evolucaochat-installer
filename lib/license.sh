#!/usr/bin/env bash
set -Eeuo pipefail

: "${INSTALLER_VERSION:=1.0.0}"
: "${INSTALL_ROOT:=/opt/evolucaochat}"
: "${CACHE_DIR:=$INSTALL_ROOT/cache}"
: "${RELEASE_PUBLIC_KEY:=$INSTALLER_DIR/keys/release-public.pem}"
: "${INSTALLATION_ID_FILE:=$INSTALL_ROOT/installation-id}"
: "${DISTRIBUTION_BASE_URL:=https://downloads.evolucaochat.com.br}"

readonly HOMOLOGATION_LICENSE_KEY='EVOLUCAOCHAT-TESTE-2026'
readonly RELEASE_FILES=(
  manifest.json
  manifest.sig
  checksums.sha256
  evolucaochat-images.tar.zst
  evolucaochat-deployment.tar.zst
)

license_error() {
  local message="$1"
  printf '%s\n' "$message" >&2
  die 40 "$message"
}

version_at_least() {
  local actual="$1"
  local required="$2"
  local actual_major actual_minor actual_patch required_major required_minor required_patch
  IFS=. read -r actual_major actual_minor actual_patch <<< "$actual"
  IFS=. read -r required_major required_minor required_patch <<< "$required"
  (( 10#$actual_major > 10#$required_major )) && return 0
  (( 10#$actual_major < 10#$required_major )) && return 1
  (( 10#$actual_minor > 10#$required_minor )) && return 0
  (( 10#$actual_minor < 10#$required_minor )) && return 1
  (( 10#$actual_patch >= 10#$required_patch ))
}

validate_manifest_shape() {
  local release_dir="$1"
  jq -e '
    .schemaVersion == 2 and
    (keys | sort == ["createdAt", "deploymentBundle", "imagesBundle", "minInstallerVersion", "releaseVersion", "schemaVersion"]) and
    (.releaseVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$")) and
    (.minInstallerVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.imagesBundle | keys | sort == ["bytes", "key", "sha256"]) and
    (.deploymentBundle | keys | sort == ["bytes", "key", "sha256"]) and
    .imagesBundle.key == "evolucaochat-images.tar.zst" and
    .deploymentBundle.key == "evolucaochat-deployment.tar.zst" and
    all(.imagesBundle, .deploymentBundle;
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.bytes | type == "number" and floor == . and . > 0)
    )
  ' "$release_dir/manifest.json" >/dev/null 2>&1 || license_error 'manifesto do release invalido'
}

verify_manifest_signature() {
  local release_dir="$1"
  [[ -s "$RELEASE_PUBLIC_KEY" ]] || license_error 'chave publica do release ausente'
  openssl dgst -sha256 \
    -verify "$RELEASE_PUBLIC_KEY" \
    -signature "$release_dir/manifest.sig" \
    "$release_dir/manifest.json" >/dev/null 2>&1 || license_error 'assinatura RSA do manifesto invalida'
}

verify_release_checksums() {
  local release_dir="$1"
  local actual_names
  local expected_names=$'evolucaochat-deployment.tar.zst\nevolucaochat-images.tar.zst\nmanifest.json\nmanifest.sig'

  actual_names="$(awk 'NF == 2 { name=$2; sub(/^\*/, "", name); print name }' "$release_dir/checksums.sha256" | sort)"
  if [[ "$actual_names" != "$expected_names" ]]; then
    license_error 'lista de checksums do release invalida'
  fi
  (
    cd "$release_dir"
    sha256sum -c checksums.sha256 >/dev/null 2>&1
  ) || license_error 'checksums do release invalidos'
}

verify_manifest_bundle_metadata() {
  local release_dir="$1"
  local field filename expected_sha expected_bytes actual_sha actual_bytes
  while read -r field filename; do
    expected_sha="$(jq -r ".${field}.sha256" "$release_dir/manifest.json")"
    expected_bytes="$(jq -r ".${field}.bytes" "$release_dir/manifest.json")"
    actual_sha="$(sha256sum "$release_dir/$filename" | awk '{print $1}')"
    actual_bytes="$(wc -c < "$release_dir/$filename" | tr -d ' ')"
    [[ "$actual_sha" == "$expected_sha" && "$actual_bytes" == "$expected_bytes" ]] ||
      license_error "metadados do pacote $filename invalidos"
  done <<'BUNDLES'
imagesBundle evolucaochat-images.tar.zst
deploymentBundle evolucaochat-deployment.tar.zst
BUNDLES
}

verify_release_directory() {
  local release_dir="$1"
  local file minimum_version
  for file in "${RELEASE_FILES[@]}"; do
    [[ -f "$release_dir/$file" && -s "$release_dir/$file" ]] || license_error "arquivo obrigatorio ausente no release: $file"
  done
  validate_manifest_shape "$release_dir"
  verify_manifest_signature "$release_dir"
  verify_release_checksums "$release_dir"
  verify_manifest_bundle_metadata "$release_dir"

  minimum_version="$(jq -r '.minInstallerVersion' "$release_dir/manifest.json")"
  version_at_least "$INSTALLER_VERSION" "$minimum_version" ||
    license_error "release requer instalador $minimum_version ou superior"
}

cache_verified_release() {
  local release_dir="$1"
  local staging file
  mkdir -p "$INSTALL_ROOT"
  chmod 700 "$INSTALL_ROOT"
  staging="$(mktemp -d "$INSTALL_ROOT/.release-cache.XXXXXX")"
  for file in "${RELEASE_FILES[@]}"; do
    cp -- "$release_dir/$file" "$staging/$file"
  done
  verify_release_directory "$staging"
  mkdir -p "$CACHE_DIR"
  chmod 700 "$CACHE_DIR"
  for file in "${RELEASE_FILES[@]}"; do
    cp -- "$staging/$file" "$CACHE_DIR/$file"
  done
  chmod 600 "$CACHE_DIR"/*
  rm -rf -- "$staging"
}

ensure_installation_id() {
  local installation_id

  mkdir -p "$INSTALL_ROOT"
  chmod 700 "$INSTALL_ROOT"
  if [[ -e "$INSTALLATION_ID_FILE" ]]; then
    [[ -f "$INSTALLATION_ID_FILE" && ! -L "$INSTALLATION_ID_FILE" ]] ||
      license_error 'identificador local de instalacao invalido'
    installation_id="$(cat "$INSTALLATION_ID_FILE")"
    [[ "$installation_id" =~ ^[0-9a-f]{64}$ ]] ||
      license_error 'identificador local de instalacao invalido'
  else
    installation_id="$(openssl rand -hex 32)"
    [[ "$installation_id" =~ ^[0-9a-f]{64}$ ]] ||
      license_error 'nao foi possivel criar identificador local de instalacao'
    printf '%s\n' "$installation_id" > "$INSTALLATION_ID_FILE"
    chmod 600 "$INSTALLATION_ID_FILE"
  fi
  printf '%s' "$installation_id"
}

commercial_authorization_payload() {
  local installation_id="$1"
  local installed_version=''

  if [[ -s "$CACHE_DIR/manifest.json" ]]; then
    installed_version="$(jq -r '.releaseVersion // empty' "$CACHE_DIR/manifest.json")"
  fi
  jq -n \
    --arg buyer_email "$BUYER_EMAIL" \
    --arg period_key "$LICENSE_KEY" \
    --arg installation_id "$installation_id" \
    --arg domain_app "$DOMAIN_APP" \
    --arg domain_api "$DOMAIN_API" \
    --arg domain_portainer "$DOMAIN_PORTAINER" \
    --arg installed_version "$installed_version" \
    '{buyerEmail:$buyer_email,periodKey:$period_key,installationId:$installation_id,domainApp:$domain_app,domainApi:$domain_api,domainPortainer:$domain_portainer} + (if $installed_version == "" then {} else {installedVersion:$installed_version} end)'
}

validate_commercial_authorization() {
  local response_file="$1"
  local expected_names
  expected_names="$(printf '%s\n' "${RELEASE_FILES[@]}" | jq -R . | jq -s 'sort')"

  jq -e --argjson expected_names "$expected_names" '
    type == "object" and
    (keys | sort == ["artifacts", "expiresInSeconds", "releaseVersion"]) and
    (.releaseVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$")) and
    (.expiresInSeconds | type == "number" and floor == . and . > 0) and
    (.artifacts | type == "array" and length == 5) and
    ([.artifacts[].name] | sort == $expected_names) and
    all(.artifacts[];
      (keys | sort == ["name", "url"]) and
      (.name | type == "string") and
      (.url | type == "string" and startswith("/v1/downloads/"))
    )
  ' "$response_file" >/dev/null 2>&1 || license_error 'resposta de autorizacao comercial invalida'
}

request_commercial_authorization() {
  local installation_id="$1"
  local response_file="$2"
  local payload

  [[ "$DISTRIBUTION_BASE_URL" == 'https://downloads.evolucaochat.com.br' ]] ||
    license_error 'origem de distribuicao comercial invalida'
  register_secret "$LICENSE_KEY"
  payload="$(commercial_authorization_payload "$installation_id")"
  curl --fail --silent --show-error \
    --request POST \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    --output "$response_file" \
    "$DISTRIBUTION_BASE_URL/v1/releases/authorize" ||
    license_error 'autorizacao comercial recusada ou indisponivel'
  validate_commercial_authorization "$response_file"
}

download_authorized_release() {
  local response_file="$1"
  local release_dir="$2"
  local filename relative_url token

  mkdir -p "$release_dir"
  chmod 700 "$release_dir"
  for filename in "${RELEASE_FILES[@]}"; do
    relative_url="$(jq -r --arg filename "$filename" '.artifacts[] | select(.name == $filename) | .url' "$response_file")"
    [[ "$relative_url" == "/v1/downloads/"*"/$filename" ]] ||
      license_error 'URL de download comercial invalida'
    token="${relative_url#/v1/downloads/}"
    token="${token%/$filename}"
    [[ "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]] ||
      license_error 'URL de download comercial invalida'
    curl --fail --silent --show-error \
      --location \
      --proto '=https' \
      --tlsv1.2 \
      --output "$release_dir/$filename" \
      "$DISTRIBUTION_BASE_URL$relative_url" ||
      license_error "falha ao baixar artefato autorizado: $filename"
  done
}

activate_commercial_release() {
  local installation_id authorization_file release_dir

  installation_id="$(ensure_installation_id)"
  authorization_file="$(mktemp "$INSTALL_ROOT/.authorization.XXXXXX")"
  release_dir="$(mktemp -d "$INSTALL_ROOT/.release-download.XXXXXX")"
  request_commercial_authorization "$installation_id" "$authorization_file"
  download_authorized_release "$authorization_file" "$release_dir"
  cache_verified_release "$release_dir"
  rm -f -- "$authorization_file"
  rm -rf -- "$release_dir"
  RELEASE_VERSION="$(jq -r '.releaseVersion' "$CACHE_DIR/manifest.json")"
  export RELEASE_VERSION
  log "release comercial $RELEASE_VERSION validado e armazenado"
}

activate_test_release() {
  local release_dir="${1:-}"
  local supplied_key="${2:-}"

  register_secret "$supplied_key"
  [[ "${INSTALLER_TEST_MODE:-}" == 1 ]] || license_error 'a versao comercial ainda exige licenca; modo de homologacao nao habilitado'
  [[ -n "$release_dir" ]] || license_error 'diretorio local de release obrigatorio'
  [[ -d "$release_dir" ]] || license_error 'diretorio local de release invalido'
  [[ "$supplied_key" == "$HOMOLOGATION_LICENSE_KEY" ]] || license_error 'chave de homologacao invalida'

  cache_verified_release "$release_dir"
  RELEASE_VERSION="$(jq -r '.releaseVersion' "$CACHE_DIR/manifest.json")"
  export RELEASE_VERSION
  log "release local $RELEASE_VERSION validado e armazenado"
}
