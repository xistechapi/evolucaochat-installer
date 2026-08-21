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

  if [[ "$password" != "$confirmation" ]]; then
    printf '%s' 'as senhas nao conferem'
    return 1
  fi
  if (( ${#password} < 12 )); then
    printf '%s' 'deve ter ao menos 12 caracteres'
    return 1
  fi
  if [[ ! "$password" =~ [[:upper:]] ]]; then
    printf '%s' 'inclua uma letra maiuscula'
    return 1
  fi
  if [[ ! "$password" =~ [[:lower:]] ]]; then
    printf '%s' 'inclua uma letra minuscula'
    return 1
  fi
  if [[ ! "$password" =~ [[:digit:]] ]]; then
    printf '%s' 'inclua um numero'
    return 1
  fi
  if [[ ! "$password" =~ [^[:alnum:]] ]]; then
    printf '%s' 'inclua um caractere especial'
    return 1
  fi
}

collect_portainer_password() {
  local password confirmation validation_error

  while true; do
    password=''
    confirmation=''

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

    if validation_error="$(validate_portainer_password_pair "$password" "$confirmation")"; then
      PORTAINER_ADMIN_PASSWORD="$password"
      export PORTAINER_ADMIN_PASSWORD
      return 0
    fi

    printf 'Senha do Portainer invalida: %s.\nTente novamente.\n\n' "$validation_error" >&2
  done
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

  read -r -p 'E-mail ACME (para emitir e renovar o certificado HTTPS): ' acme_email_input || input_error 'e-mail ACME obrigatorio'
  ACME_EMAIL="$(normalize_email "$acme_email_input")" || input_error 'e-mail ACME invalido'

  read -r -p 'Dominio do painel (ex.: app.seudominio.com.br): ' domain_app_input || input_error 'dominio do painel obrigatorio'
  validate_domain "$domain_app_input"
  DOMAIN_APP="${domain_app_input,,}"

  read -r -p 'Dominio da API (ex.: api.seudominio.com.br): ' domain_api_input || input_error 'dominio da API obrigatorio'
  validate_domain "$domain_api_input"
  DOMAIN_API="${domain_api_input,,}"

  read -r -p 'Dominio do Portainer (ex.: portainer.seudominio.com.br): ' domain_portainer_input || input_error 'dominio do Portainer obrigatorio'
  validate_domain "$domain_portainer_input"
  DOMAIN_PORTAINER="${domain_portainer_input,,}"

  if [[ "$DOMAIN_APP" == "$DOMAIN_API" || "$DOMAIN_APP" == "$DOMAIN_PORTAINER" || "$DOMAIN_API" == "$DOMAIN_PORTAINER" ]]; then
    input_error 'dominios devem ser distintos'
  fi

  collect_portainer_password
}
