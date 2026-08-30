#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export INSTALL_ROOT="$test_root/install"
export SECRETS_DIR="$INSTALL_ROOT/secrets"
export CREDENTIALS_FILE="$INSTALL_ROOT/credentials.txt"
export STATE_FILE="$INSTALL_ROOT/state.json"
export LOG_FILE="$INSTALL_ROOT/installer.log"
export DOMAIN_APP='app.example.com'
export DOMAIN_API='api.example.com'
export DOMAIN_PORTAINER='portainer.example.com'
export PORTAINER_ADMIN_PASSWORD='SenhaSecreta#2026'

mkdir -p "$INSTALL_ROOT"
source "$repo_root/install.sh"
completion_output="$(finalize_installation)"

[[ "$completion_output" == *'INSTALACAO CONCLUIDA COM SUCESSO'* ]]
[[ "$completion_output" == *'Painel: https://app.example.com'* ]]
[[ "$completion_output" == *'API: https://api.example.com'* ]]
[[ "$completion_output" == *'Portainer: https://portainer.example.com'* ]]
[[ "$completion_output" == *'Usuario do Portainer: admin'* ]]
[[ "$completion_output" == *"Credenciais protegidas em $CREDENTIALS_FILE"* ]]
[[ "$completion_output" == *'Voce pode fechar este terminal.'* ]]
[[ "$completion_output" != *"$PORTAINER_ADMIN_PASSWORD"* ]]

printf 'completion message: PASS\n'
