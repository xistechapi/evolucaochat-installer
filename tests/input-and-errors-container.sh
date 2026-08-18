#!/usr/bin/env sh
set -eu

apk add --no-cache bash jq >/dev/null

bash <<'BASH'
set -Eeuo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/repo/lib"
for source_file in common.sh input.sh; do
  tr -d '\r' < "/repo/lib/$source_file" > "$test_root/repo/lib/$source_file"
done

export STATE_FILE="$test_root/state.json"
export LOG_FILE="$test_root/installer.log"

source "$test_root/repo/lib/common.sh"
source "$test_root/repo/lib/input.sh"

inputs=('curta' 'curta' 'SenhaForte!2026' 'SenhaForte!2026')
input_index=0
read() {
  local target="${!#}"
  printf -v "$target" '%s' "${inputs[$input_index]}"
  ((input_index += 1)) || true
}

password_output_file="$test_root/password-output"
collect_portainer_password 2>"$password_output_file"
password_output="$(cat "$password_output_file")"
unset -f read
[[ "$PORTAINER_ADMIN_PASSWORD" == 'SenhaForte!2026' ]]
[[ "$password_output" == *'Senha do Portainer invalida: deve ter ao menos 12 caracteres.'* ]]
[[ "$password_output" == *'Tente novamente.'* ]]

failing_step() {
  printf 'falha simulada de acesso\n' >&2
  return 40
}

set +e
step_output="$(run_step activation_and_download failing_step 2>&1)"
step_result=$?
set -e

[[ $step_result -eq 40 ]]
[[ "$step_output" == *'ERRO: a etapa "activation_and_download" nao foi concluida.'* ]]
[[ "$step_output" == *"Consulte o diagnostico protegido em $LOG_FILE"* ]]
[[ "$step_output" == *'Falha ao validar o acesso a versao. Confira o e-mail e a chave de licenca.'* ]]

printf 'input and terminal errors: PASS\n'
BASH
