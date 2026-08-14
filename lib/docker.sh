#!/usr/bin/env bash
set -Eeuo pipefail

: "${OS_RELEASE_FILE:=/etc/os-release}"
: "${DOCKER_KEYRING_DIR:=/etc/apt/keyrings}"
: "${DOCKER_SOURCE_DIR:=/etc/apt/sources.list.d}"

docker_error() {
  local message="$1"
  printf '%s\n' "$message" >&2
  die 30 "$message"
}

install_base_packages() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg jq openssl zstd iproute2 dnsutils
}

docker_engine_healthy() {
  command -v docker >/dev/null 2>&1 &&
    systemctl is-active --quiet docker &&
    docker info >/dev/null 2>&1
}

docker_compose_healthy() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

configure_docker_repository() {
  local distro codename architecture keyring source_file

  # shellcheck disable=SC1090
  source "$OS_RELEASE_FILE"
  distro="${ID:-}"
  codename="${VERSION_CODENAME:-}"
  [[ "$distro" == ubuntu || "$distro" == debian ]] || docker_error 'distribuicao invalida para o repositorio Docker'
  [[ -n "$codename" ]] || docker_error 'codename da distribuicao ausente'
  architecture="$(dpkg --print-architecture)"

  mkdir -p "$DOCKER_KEYRING_DIR" "$DOCKER_SOURCE_DIR"
  keyring="$DOCKER_KEYRING_DIR/docker.asc"
  source_file="$DOCKER_SOURCE_DIR/docker.list"
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o "$keyring"
  chmod a+r "$keyring"
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$architecture" "$keyring" "$distro" "$codename" > "$source_file"
}

install_docker_engine() {
  configure_docker_repository
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

ensure_docker() {
  if docker_engine_healthy; then
    log 'Docker Engine saudavel encontrado; reutilizando'
    return 0
  fi

  install_docker_engine
  docker_engine_healthy || docker_error 'Docker Engine nao ficou saudavel apos a instalacao'
}

ensure_compose() {
  if docker_compose_healthy; then
    log 'Docker Compose v2 encontrado; reutilizando'
    return 0
  fi

  configure_docker_repository
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-compose-plugin
  docker_compose_healthy || docker_error 'Docker Compose v2 nao ficou disponivel apos a instalacao'
}
