#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly PUBLIC_INSTALLER_BASE_URL='https://raw.githubusercontent.com/xistechapi/evolucaochat-installer/main'
readonly -a PUBLIC_INSTALLER_FILES=(
  install.sh
  lib/common.sh
  lib/input.sh
  lib/preflight.sh
  lib/docker.sh
  lib/license.sh
  lib/secrets.sh
  lib/deploy.sh
  keys/release-public.pem
)

bootstrap_error() {
  printf 'ERRO: %s\n' "$1" >&2
  return 1
}

download_public_installer() {
  local destination="$1"
  local staging relative_path target

  [[ "$destination" == /* ]] || bootstrap_error 'diretorio temporario do instalador invalido'
  [[ ! -e "$destination" && ! -L "$destination" ]] || bootstrap_error 'diretorio temporario do instalador ja existe'
  staging="$(mktemp -d "${TMPDIR:-/tmp}/evolucaochat-installer.XXXXXX")"
  trap 'rm -rf -- "$staging"' RETURN

  for relative_path in "${PUBLIC_INSTALLER_FILES[@]}"; do
    target="$staging/$relative_path"
    mkdir -p "$(dirname "$target")"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --output "$target" \
      "$PUBLIC_INSTALLER_BASE_URL/$relative_path" || {
        rm -rf -- "$staging"
        trap - RETURN
        bootstrap_error "nao foi possivel baixar o instalador publico ($relative_path)"
        return 1
      }
  done

  [[ -s "$staging/install.sh" && -s "$staging/keys/release-public.pem" ]] || {
    rm -rf -- "$staging"
    trap - RETURN
    bootstrap_error 'pacote publico do instalador incompleto'
    return 1
  }
  chmod 700 "$staging"
  find "$staging" -type d -exec chmod 700 {} +
  find "$staging" -type f -exec chmod 600 {} +
  mv -- "$staging" "$destination"
  trap - RETURN
}

main() {
  local install_dir
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || bootstrap_error 'execute com sudo'
  install_dir="$(mktemp -d "${TMPDIR:-/tmp}/evolucaochat-installer-run.XXXXXX")"
  rm -rf -- "$install_dir"
  download_public_installer "$install_dir"
  bash "$install_dir/install.sh" "$@"
  local result=$?
  rm -rf -- "$install_dir"
  return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
