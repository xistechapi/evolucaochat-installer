#!/usr/bin/env bash
set -Eeuo pipefail

: "${STATE_FILE:=/opt/evolucaochat/state.json}"
: "${LOG_FILE:=/var/log/evolucaochat-installer.log}"
REGISTERED_SECRETS=()

local_docker_storage_root() {
  local endpoint storage_root canonical
  endpoint="${DOCKER_HOST:-$(docker context inspect --format '{{(index .Endpoints "docker").Host}}')}" || return 1
  [[ "$endpoint" == unix:///var/run/docker.sock || "$endpoint" == unix:///run/docker.sock ]] || return 1
  storage_root="$(docker info --format '{{.DockerRootDir}}')" || return 1
  [[ "$storage_root" =~ ^/[A-Za-z0-9._/-]+$ && "$storage_root" != / && -d "$storage_root" && ! -L "$storage_root" ]] || return 1
  canonical="$(readlink -f -- "$storage_root")" || return 1
  [[ "$canonical" == "$storage_root" ]] || return 1
  printf '%s\n' "$storage_root"
}

local_containerd_storage_root() {
  local service dump root_line storage_root canonical
  service="$(systemctl show containerd --property=ExecStart --value)" || return 1
  # Support the standard rootful system service, not custom daemon arguments/pools.
  [[ "$service" == *'argv[]=/usr/bin/containerd ;'* ]] || return 1
  dump="$(containerd config dump)" || return 1
  # Custom snapshotter roots and imported pool configurations need assisted review.
  local override
  while IFS= read -r override; do
    override="$(sed -E "s/^[^=]*=[[:space:]]*//; s/[\"']//g; s/[[:space:]]//g" <<< "$override")"
    [[ -z "$override" ]] || return 1
  done < <(grep -E '^[[:space:]]*(root_path|pool_name)[[:space:]]*=' <<< "$dump" || true)
  root_line="$(awk '/^[[:space:]]*\[/ {exit} /^[[:space:]]*root[[:space:]]*=/ {print}' <<< "$dump")"
  storage_root="$(sed -E "s/^[[:space:]]*root[[:space:]]*=[[:space:]]*[\"']/ /; s/[\"'][[:space:]]*$//; s/^ //" <<< "$root_line")"
  [[ "$storage_root" =~ ^/[A-Za-z0-9._/-]+$ && "$storage_root" != / && -d "$storage_root" && ! -L "$storage_root" ]] || return 1
  canonical="$(readlink -f -- "$storage_root")" || return 1
  [[ "$canonical" == "$storage_root" ]] || return 1
  printf '%s\n' "$storage_root"
}

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
      # Only promote known local diagnostics, never arbitrary response content.
      for line in \
        'Chave de licenca invalida. Confira a chave recebida e tente novamente.' \
        'Central de downloads indisponivel. Tente novamente mais tarde.' \
        'Nao foi possivel conectar a central de downloads. Confira a conexao da VPS e tente novamente.' \
        'Nao foi possivel autorizar a instalacao. Confira os dados informados e tente novamente.'; do
        if [[ -f "$output_file" ]] && grep -Fxq "$line" "$output_file"; then
          guidance="$line"
          break
        fi
      done
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

step_description() {
  case "$1" in
    dns) printf 'Verificando os dominios e o IP da VPS' ;;
    docker) printf 'Preparando o Docker e seus pacotes' ;;
    activation_and_download) printf 'Validando a licenca e baixando a versao autorizada' ;;
    prepare_deployment) printf 'Preparando os arquivos de instalacao' ;;
    secrets) printf 'Configurando as credenciais com seguranca' ;;
    load_images) printf 'Carregando as imagens do sistema' ;;
    deploy_infra) printf 'Instalando a stack de infraestrutura e o Portainer' ;;
    deploy_app) printf 'Instalando a stack do aplicativo e aguardando os servicos' ;;
    verify) printf 'Verificando os servicos e os certificados HTTPS' ;;
    notify_completion) printf 'Finalizando a instalacao' ;;
    *) printf 'Executando uma etapa da instalacao' ;;
  esac
}

step_progress_loop() {
  # UI only: never read the step output, credentials or log in this process.
  trap - ERR
  local description="$1" parent_pid="$2" started=$SECONDS elapsed sleeper=''
  local interval="${INSTALLER_PROGRESS_INTERVAL:-15}"
  [[ "$interval" =~ ^[1-9][0-9]{0,2}$ ]] || interval=15
  trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || :; wait "$sleeper" 2>/dev/null || :; fi; exit 0' TERM INT
  while kill -0 "$parent_pid" 2>/dev/null; do
    sleep "$interval" &
    sleeper=$!
    wait "$sleeper" || return 0
    sleeper=''
    kill -0 "$parent_pid" 2>/dev/null || return 0
    elapsed=$((SECONDS - started))
    printf '[AGUARDE] %s | %02d:%02d decorridos. Nao feche este terminal.\n' \
      "$description" "$((elapsed / 60))" "$((elapsed % 60))" >&2 || return 0
  done
}

run_step() {
  local name="$1"
  local function_name="$2"
  local current_state exit_code output_file had_errexit=0 description progress_pid parent_pid="$BASHPID" err_trap

  description="$(step_description "$name")"
  current_state="$(state_get "$name")"
  if [[ "$current_state" == completed ]]; then
    log "step $name already completed; skipping"
    printf '[OK] Etapa ja concluida: %s.\n' "$description" >&2
    return 0
  fi

  state_set "$name" running
  log "step $name started"
  output_file="$(mktemp "$(dirname "$STATE_FILE")/.step-output.XXXXXX")"
  printf '[INICIANDO] %s.\n' "$description" >&2
  step_progress_loop "$description" "$parent_pid" &
  progress_pid=$!
  [[ $- == *e* ]] && had_errexit=1
  # set +e alone does not suppress the entrypoint's exiting ERR handler.
  # Keep that handler inside the worker, but finish cleanup/state in the parent
  # before returning the failure to the entrypoint. trap -p is trusted shell code.
  err_trap="$(trap -p ERR)"
  trap - ERR
  set +e
  (
    [[ -z "$err_trap" ]] || eval "$err_trap"
    set -Eeuo pipefail
    "$function_name"
  ) > "$output_file" 2>&1
  exit_code=$?
  kill "$progress_pid" 2>/dev/null || :
  wait "$progress_pid" 2>/dev/null || :
  [[ -z "$err_trap" ]] || eval "$err_trap"
  (( had_errexit == 1 )) && set -e

  if (( exit_code == 0 )); then
    log_step_output "$name" "$output_file"
    rm -f "$output_file"
    state_set "$name" completed
    log "step $name completed"
    printf '[OK] Concluido: %s.\n' "$description" >&2
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
