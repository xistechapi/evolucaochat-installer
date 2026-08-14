#!/usr/bin/env bash
set -Eeuo pipefail

input_error() {
  local message="$1"
  printf '%s\n' "$message" >&2
  die 20 "$message"
}

is_valid_domain() {
  local domain="$1"
  local label
  local -a labels

  (( ${#domain} <= 253 )) || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_domain() {
  local domain="${1,,}"
  is_valid_domain "$domain" || input_error "dominio invalido: $1"
}

normalize_email() {
  local email="${1,,}"
  local local_part domain

  [[ "$email" != *[[:space:]]* ]] || return 1
  [[ "$email" == *@* && "$email" != *@*@* ]] || return 1
  local_part="${email%@*}"
  domain="${email##*@}"
  [[ -n "$local_part" && ${#local_part} -le 64 && ${#email} -le 254 ]] || return 1
  [[ "$local_part" =~ ^[a-z0-9.!#%\&\'*+/=?^_\`{|}~-]+$ ]] || return 1
  is_valid_domain "$domain" || return 1
  printf '%s' "$email"
}

validate_portainer_password_pair() {
  local password="$1"
  local confirmation="$2"

  [[ "$password" == "$confirmation" ]] || input_error 'senhas do Portainer nao conferem'
  [[ ${#password} -ge 12 ]] || input_error 'senha do Portainer fraca'
  [[ "$password" =~ [[:upper:]] ]] || input_error 'senha do Portainer fraca'
  [[ "$password" =~ [[:lower:]] ]] || input_error 'senha do Portainer fraca'
  [[ "$password" =~ [[:digit:]] ]] || input_error 'senha do Portainer fraca'
  [[ "$password" =~ [^[:alnum:]] ]] || input_error 'senha do Portainer fraca'
}

collect_portainer_password() {
  local password confirmation

  read -r -s -p 'Senha do Portainer: ' password || {
    register_secret "$password"
    input_error 'senha do Portainer obrigatoria'
  }
  register_secret "$password"
  printf '\n' >&2

  read -r -s -p 'Confirme a senha do Portainer: ' confirmation || {
    register_secret "$confirmation"
    input_error 'confirmacao da senha do Portainer obrigatoria'
  }
  register_secret "$confirmation"
  printf '\n' >&2

  validate_portainer_password_pair "$password" "$confirmation"
  PORTAINER_ADMIN_PASSWORD="$password"
  export PORTAINER_ADMIN_PASSWORD
}

collect_inputs() {
  local buyer_email_input acme_email_input license_key_input
  local domain_app_input domain_api_input domain_portainer_input

  read -r -p 'E-mail do comprador: ' buyer_email_input || input_error 'e-mail do comprador obrigatorio'
  BUYER_EMAIL="$(normalize_email "$buyer_email_input")" || input_error 'e-mail do comprador invalido'

  read -r -s -p 'Chave de licenca: ' license_key_input || input_error 'chave de licenca obrigatoria'
  printf '\n' >&2
  register_secret "$license_key_input"
  [[ -n "$license_key_input" ]] || input_error 'chave de licenca obrigatoria'
  LICENSE_KEY="$license_key_input"

  read -r -p 'E-mail ACME: ' acme_email_input || input_error 'e-mail ACME obrigatorio'
  ACME_EMAIL="$(normalize_email "$acme_email_input")" || input_error 'e-mail ACME invalido'

  read -r -p 'Dominio do painel: ' domain_app_input || input_error 'dominio do painel obrigatorio'
  validate_domain "$domain_app_input"
  DOMAIN_APP="${domain_app_input,,}"

  read -r -p 'Dominio da API: ' domain_api_input || input_error 'dominio da API obrigatorio'
  validate_domain "$domain_api_input"
  DOMAIN_API="${domain_api_input,,}"

  read -r -p 'Dominio do Portainer: ' domain_portainer_input || input_error 'dominio do Portainer obrigatorio'
  validate_domain "$domain_portainer_input"
  DOMAIN_PORTAINER="${domain_portainer_input,,}"

  if [[ "$DOMAIN_APP" == "$DOMAIN_API" || "$DOMAIN_APP" == "$DOMAIN_PORTAINER" || "$DOMAIN_API" == "$DOMAIN_PORTAINER" ]]; then
    input_error 'dominios devem ser distintos'
  fi

  collect_portainer_password
}
