#!/usr/bin/env bash
set -Eeuo pipefail

: "${STATE_FILE:=/opt/evolucaochat/state.json}"
: "${LOG_FILE:=/var/log/evolucaochat-installer.log}"
REGISTERED_SECRETS=()

die() {
  local code="$1"
  local message="$2"
  log "ERROR: $message"
  exit "$code"
}

register_secret() {
  local value
  for value in "$@"; do
    [[ -n "$value" ]] || continue
    REGISTERED_SECRETS+=("$value")
  done
}

redact() {
  local value="$1"
  local secret

  for secret in "${REGISTERED_SECRETS[@]}"; do
    value="${value//"$secret"/[REDACTED]}"
  done
  printf '%s' "$value"
}

log() {
  local message="$1"
  local directory
  directory="$(dirname "$LOG_FILE")"
  mkdir -p "$directory"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(redact "$message")" >> "$LOG_FILE"
}

state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  jq -r --arg key "$key" '.steps[$key] // empty' "$STATE_FILE"
}

state_set() {
  local key="$1"
  local value="$2"
  local state_dir temp_file

  state_dir="$(dirname "$STATE_FILE")"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  temp_file="$(mktemp "$state_dir/.state.json.XXXXXX")"
  if [[ -f "$STATE_FILE" ]]; then
    jq --arg key "$key" --arg value "$value" '.steps //= {} | .steps[$key] = $value' "$STATE_FILE" > "$temp_file"
  else
    jq --arg key "$key" --arg value "$value" '.steps //= {} | .steps[$key] = $value' > "$temp_file" <<< '{}'
  fi
  chmod 600 "$temp_file"
  mv -f "$temp_file" "$STATE_FILE"
}

log_step_output() {
  local name="$1"
  local output_file="$2"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    log "step $name output: $line"
  done < "$output_file"
}

show_step_failure() {
  local name="$1"
  local output_file="${2:-}"
  local guidance='Revise os dados informados e tente novamente.'
  local line

  case "$name" in
    activation_and_download)
      guidance='Falha ao validar o acesso a versao. Confira o e-mail e a chave de licenca.'
      ;;
    dns)
      guidance='Confira se os tres dominios apontam para o IP desta VPS e tente novamente.'
      ;;
    docker)
      guidance='Nao foi possivel preparar o Docker. Verifique a conexao da VPS e tente novamente.'
      ;;
  esac

  printf '\nERRO: a etapa "%s" nao foi concluida.\n' "$name" >&2
  printf '%s\n' "$guidance" >&2
  if [[ -n "$output_file" && -s "$output_file" ]]; then
    printf '\nDetalhes tecnicos (dados sensiveis ocultos):\n' >&2
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\n' "$(redact "$line")" >&2
    done < <(tail -n 30 "$output_file")
  fi
  printf 'Consulte o diagnostico protegido em %s\n' "$LOG_FILE" >&2
}

run_step() {
  local name="$1"
  local function_name="$2"
  local current_state exit_code output_file had_errexit=0

  current_state="$(state_get "$name")"
  if [[ "$current_state" == completed ]]; then
    log "step $name already completed; skipping"
    return 0
  fi

  state_set "$name" running
  log "step $name started"
  output_file="$(mktemp "$(dirname "$STATE_FILE")/.step-output.XXXXXX")"
  [[ $- == *e* ]] && had_errexit=1
  set +e
  (
    set -Eeuo pipefail
    "$function_name"
  ) > "$output_file" 2>&1
  exit_code=$?
  (( had_errexit == 1 )) && set -e

  if (( exit_code == 0 )); then
    log_step_output "$name" "$output_file"
    rm -f "$output_file"
    state_set "$name" completed
    log "step $name completed"
    return 0
  else
    log_step_output "$name" "$output_file"
    state_set "$name" "failed:$exit_code"
    log "step $name failed with exit code $exit_code"
    show_step_failure "$name" "$output_file"
    rm -f "$output_file"
    return "$exit_code"
  fi
}
