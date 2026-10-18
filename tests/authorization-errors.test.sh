#!/usr/bin/env bash
set -Eeuo pipefail
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export INSTALL_ROOT="$test_root/install" LOG_FILE="$test_root/install.log" STATE_FILE="$test_root/state.json"
source "$INSTALLER_DIR/lib/common.sh"
source "$INSTALLER_DIR/lib/license.sh"
BUYER_EMAIL='buyer@example.com'
LICENSE_KEY='secret-never-display'
DOMAIN_APP='app.example.com'
DOMAIN_API='api.example.com'
DOMAIN_PORTAINER='portainer.example.com'
for status in 401 503 000 400; do
  case "$status" in
    401) expected='Chave de licenca invalida. Confira a chave recebida e tente novamente.' ;;
    503) expected='Central de downloads indisponivel. Tente novamente mais tarde.' ;;
    000) expected='Nao foi possivel conectar a central de downloads. Confira a conexao da VPS e tente novamente.' ;;
    400) expected='Nao foi possivel autorizar a instalacao. Confira os dados informados e tente novamente.' ;;
  esac
  curl() { printf '%s' "$status"; return 22; }
  exit_code=0
  output="$(request_commercial_authorization 'test-installation' "$test_root/response" 2>&1)" || exit_code=$?
  [[ "$exit_code" == 40 && "$output" == *"$expected"* ]] || { printf 'FAIL: wrong message for HTTP %s\n' "$status"; exit 1; }
  [[ "$output" != *"$LICENSE_KEY"* ]] || { printf 'FAIL: leaked key\n'; exit 1; }
  if declare -F show_step_failure >/dev/null; then
    printf '%s\n' "$output" > "$test_root/step-output"
    notice="$(show_step_failure activation_and_download "$test_root/step-output" 2>&1)"
    [[ "$notice" == *"$expected"* && "$notice" != *'Confira o e-mail e a chave'* ]] || { printf 'FAIL: generic terminal guidance\n'; exit 1; }
  fi
done
# A valid response still reaches schema validation and preserves all five artifacts.
curl() {
  local destination=''
  while (( $# )); do
    if [[ "$1" == --output ]]; then destination="$2"; shift 2; else shift; fi
  done
  jq -n --argjson names '["manifest.json","manifest.sig","checksums.sha256","evolucaochat-images.tar.zst","evolucaochat-deployment.tar.zst"]' \
    '{releaseVersion:"1.1.5",expiresInSeconds:900,artifacts:($names|map({name:.,url:("/v1/downloads/test/"+.)}))}' > "$destination"
  printf '200'
}
request_commercial_authorization 'test-installation' "$test_root/success"
[[ "$(jq -r .releaseVersion "$test_root/success")" == '1.1.5' ]]
! grep -Fq "$LICENSE_KEY" "$LOG_FILE"
printf 'authorization errors: PASS\n'
