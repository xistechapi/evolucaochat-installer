#!/usr/bin/env bash
set -Eeuo pipefail

: "${OS_RELEASE_FILE:=/etc/os-release}"
: "${MEMINFO_FILE:=/proc/meminfo}"
: "${PROC_NET_TCP_FILES:=/proc/net/tcp /proc/net/tcp6}"

preflight_error() {
  local message="$1"
  printf '%s\n' "$message" >&2
  die 21 "$message"
}

require_root() {
  local effective_uid="${1:-$EUID}"
  [[ "$effective_uid" == 0 ]] || preflight_error 'execute o instalador como root'
}

read_os_release_value() {
  local wanted_key="$1"
  local key value

  while IFS='=' read -r key value; do
    [[ "$key" == "$wanted_key" ]] || continue
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
    return 0
  done < "$OS_RELEASE_FILE"
  return 1
}

check_platform() {
  local distribution version architecture

  [[ -r "$OS_RELEASE_FILE" ]] || preflight_error 'sistema operacional nao suportado'
  distribution="$(read_os_release_value ID)" || preflight_error 'sistema operacional nao suportado'
  version="$(read_os_release_value VERSION_ID)" || preflight_error 'sistema operacional nao suportado'
  architecture="${ARCH_OVERRIDE:-$(uname -m)}"

  case "$architecture" in
    amd64|x86_64) ;;
    *) preflight_error "arquitetura nao suportada: $architecture" ;;
  esac

  case "$distribution:$version" in
    ubuntu:22.04|ubuntu:24.04|debian:12) ;;
    *) preflight_error "sistema operacional nao suportado: $distribution $version" ;;
  esac
}

check_resources() {
  local cpu_count memory_kb disk_available_kb confirmation

  cpu_count="$(nproc)" || preflight_error 'nao foi possivel medir CPU'
  memory_kb="$(awk '/^MemTotal:/ { print $2; exit }' "$MEMINFO_FILE")" || preflight_error 'nao foi possivel medir RAM'
  disk_available_kb="$(df -Pk /opt | awk 'NR == 2 { print $4; exit }')" || preflight_error 'nao foi possivel medir disco em /opt'

  [[ "$cpu_count" =~ ^[0-9]+$ ]] || preflight_error 'nao foi possivel medir CPU'
  [[ "$memory_kb" =~ ^[0-9]+$ ]] || preflight_error 'nao foi possivel medir RAM'
  [[ "$disk_available_kb" =~ ^[0-9]+$ ]] || preflight_error 'nao foi possivel medir disco em /opt'

  (( cpu_count >= 2 )) || preflight_error 'minimo de 2 CPU nao atendido'
  (( memory_kb >= 4 * 1024 * 1024 )) || preflight_error 'minimo de 4 GB de RAM nao atendido'
  (( disk_available_kb >= 40 * 1024 * 1024 )) || preflight_error 'minimo de 40 GB livres em /opt nao atendido'

  if (( cpu_count < 4 || memory_kb < 8 * 1024 * 1024 )); then
    printf 'Recursos abaixo do recomendado (4 CPU e 8 GB RAM). Digite CONTINUAR: ' >&2
    read -r confirmation || confirmation=''
    [[ "$confirmation" == CONTINUAR ]] || preflight_error 'confirmacao CONTINUAR obrigatoria'
  fi
}

has_managed_label() {
  local labels="$1"
  [[ ",$labels," == *,com.evolucaochat.managed=true,* ]]
}

check_clean_host() {
  local security_options swarm_state containers line labels

  command -v docker > /dev/null 2>&1 || return 0

  security_options="$(docker info --format '{{json .SecurityOptions}}')" || preflight_error 'nao foi possivel inspecionar Docker'
  [[ "${security_options,,}" != *rootless* ]] || preflight_error 'Docker rootless nao e suportado'

  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')" || preflight_error 'nao foi possivel inspecionar Docker Swarm'
  [[ "$swarm_state" == inactive ]] || preflight_error 'Docker Swarm deve estar inativo'

  containers="$(docker ps -a --format '{{.ID}}|{{.Image}}|{{.Labels}}')" || preflight_error 'nao foi possivel listar containers Docker'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    labels="${line#*|}"
    labels="${labels#*|}"
    has_managed_label "$labels" || preflight_error 'containers de terceiros encontrados; use uma VPS limpa'
  done <<< "$containers"
}

managed_traefik_owns_port() {
  local wanted_port="$1"
  local containers line image name labels ports image_name

  command -v docker > /dev/null 2>&1 || return 1
  containers="$(docker ps --format '{{.Image}}|{{.Names}}|{{.Labels}}|{{.Ports}}')" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    IFS='|' read -r image name labels ports <<< "$line"
    has_managed_label "$labels" || continue
    image_name="${image##*/}"
    image_name="${image_name,,}"
    [[ "$image_name" == traefik || "$image_name" == traefik:* || "$image_name" == traefik@* ]] || continue
    [[ "$ports" == *":$wanted_port->"* ]] || continue
    return 0
  done <<< "$containers"
  return 1
}

check_ports() {
  local listeners line local_address port proc_ports

  if command -v ss >/dev/null 2>&1 && listeners="$(ss -H -ltn 2>/dev/null)"; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      read -r _ _ _ local_address _ <<< "$line"
      port="${local_address##*:}"
      case "$port" in
        80|443)
          managed_traefik_owns_port "$port" || preflight_error "porta $port ja esta em uso e nao pertence ao Traefik gerenciado"
          ;;
      esac
    done <<< "$listeners"
    return 0
  fi

  proc_ports="$(listening_http_ports_from_proc)" || preflight_error 'nao foi possivel inspecionar portas TCP'
  while IFS= read -r port || [[ -n "$port" ]]; do
    [[ -n "$port" ]] || continue
    managed_traefik_owns_port "$port" || preflight_error "porta $port ja esta em uso e nao pertence ao Traefik gerenciado"
  done <<< "$proc_ports"
}

listening_http_ports_from_proc() {
  local file found=0
  for file in $PROC_NET_TCP_FILES; do
    [[ -r "$file" ]] || continue
    found=1
    awk '
      NR > 1 && $4 == "0A" {
        count = split($2, address, ":")
        port = toupper(address[count])
        if (port == "0050") print "80"
        if (port == "01BB") print "443"
      }
    ' "$file"
  done
  (( found == 1 )) || return 1
}

is_ipv4() {
  local value="$1"
  local part
  local -a parts

  IFS='.' read -r -a parts <<< "$value"
  (( ${#parts[@]} == 4 )) || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

get_public_ipv4() {
  local public_ip
  public_ip="$(curl -4fsS --max-time 10 https://api.ipify.org)" || preflight_error 'nao foi possivel obter o IPv4 publico'
  is_ipv4 "$public_ip" || preflight_error 'IPv4 publico invalido'
  printf '%s' "$public_ip"
}

assert_dns() {
  local domain="$1"
  local public_ip="$2"
  local records resolved_ip

  records="$(getent ahostsv4 "$domain")" || preflight_error "dominio $domain nao possui registro A"
  while read -r resolved_ip _; do
    [[ "$resolved_ip" == "$public_ip" ]] && return 0
  done <<< "$records"
  preflight_error "dominio $domain nao resolve para o IP publico $public_ip"
}
