#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALLER_DIR/lib/common.sh"
source "$INSTALLER_DIR/lib/input.sh"
source "$INSTALLER_DIR/lib/preflight.sh"
source "$INSTALLER_DIR/lib/docker.sh"
source "$INSTALLER_DIR/lib/license.sh"
source "$INSTALLER_DIR/lib/secrets.sh"
source "$INSTALLER_DIR/lib/deploy.sh"

on_error() {
  local exit_code="$1"
  local line="$2"
  log "installer failed with exit code $exit_code at line $line"
  printf '\nERRO: a instalacao foi interrompida (codigo %s).\n' "$exit_code" >&2
  printf 'Consulte o diagnostico protegido em %s\n' "$LOG_FILE" >&2
  exit "$exit_code"
}

trap 'on_error $? $LINENO' ERR

installer_cli_error() {
  local message="$1"
  printf '%s\n' "$message" >&2
  die 10 "$message"
}

parse_arguments() {
  TEST_RELEASE_DIR=''
  INSTALL_MODE='commercial'
  while (( $# > 0 )); do
    case "$1" in
      --test-release-dir)
        (( $# >= 2 )) || installer_cli_error 'informe --test-release-dir com um diretorio local'
        TEST_RELEASE_DIR="$2"
        shift 2
        ;;
      *)
        installer_cli_error "parametro desconhecido: $1"
        ;;
    esac
  done

  if [[ -n "$TEST_RELEASE_DIR" ]]; then
    [[ "${INSTALLER_TEST_MODE:-}" == 1 ]] ||
      installer_cli_error 'modo de homologacao nao habilitado'
    [[ "$TEST_RELEASE_DIR" == /* ]] || installer_cli_error '--test-release-dir deve usar um caminho absoluto'
    INSTALL_MODE='test'
  fi
  export INSTALL_MODE TEST_RELEASE_DIR
}

step_preflight_static() {
  check_platform
  check_resources
  check_clean_host
  check_ports
}
step_base_packages() { install_base_packages; }
step_dns() {
  PUBLIC_IP="$(get_public_ipv4)"
  assert_dns "$DOMAIN_APP" "$PUBLIC_IP"
  assert_dns "$DOMAIN_API" "$PUBLIC_IP"
  assert_dns "$DOMAIN_PORTAINER" "$PUBLIC_IP"
}
step_docker() {
  ensure_docker
  ensure_compose
}
step_activation_and_download() {
  if [[ "$INSTALL_MODE" == test ]]; then
    activate_test_release "$TEST_RELEASE_DIR" "$LICENSE_KEY"
  else
    activate_commercial_release
  fi
}
step_prepare_deployment() { prepare_deployment_files; }
step_secrets() { generate_environment; }
step_load_images() { load_release_images; }
step_deploy_infra() { deploy_infrastructure; }
step_deploy_app() { deploy_application; }
step_verify() { verify_deployment; }
step_notify_completion() {
  printf 'Instalacao concluida. Credenciais protegidas em %s\n' "$CREDENTIALS_FILE"
}

initialize_installer_paths() {
  mkdir -p "$INSTALL_ROOT" "$SECRETS_DIR"
  chmod 700 "$INSTALL_ROOT" "$SECRETS_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
}

load_cached_release_version() {
  [[ -s "$CACHE_DIR/manifest.json" ]] || installer_cli_error 'manifesto validado ausente do cache'
  RELEASE_VERSION="$(jq -r '.releaseVersion' "$CACHE_DIR/manifest.json")"
  [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] ||
    installer_cli_error 'versao do release em cache invalida'
  export RELEASE_VERSION
}

main() {
  parse_arguments "$@"
  require_root
  initialize_installer_paths

  # jq faz parte dos pacotes-base e e necessario para o estado retomavel.
  # Por isso, somente as validacoes que usam ferramentas nativas precedem apt.
  step_preflight_static
  step_base_packages
  state_set base_packages completed

  collect_inputs
  run_step dns step_dns
  run_step docker step_docker
  run_step activation_and_download step_activation_and_download
  load_cached_release_version
  run_step prepare_deployment step_prepare_deployment
  run_step secrets step_secrets
  register_environment_secrets
  if ! release_images_available; then
    state_set load_images pending
  fi
  run_step load_images step_load_images
  state_set deploy_infra pending
  run_step deploy_infra step_deploy_infra
  state_set deploy_app pending
  run_step deploy_app step_deploy_app
  register_environment_secrets
  state_set verify pending
  run_step verify step_verify
  state_set notify_completion pending
  run_step notify_completion step_notify_completion
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
