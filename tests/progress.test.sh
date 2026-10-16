#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export STATE_FILE="$test_root/state.json" LOG_FILE="$test_root/installer.log"
export INSTALLER_PROGRESS_INTERVAL=1
source "$repo_root/lib/common.sh"
source "$repo_root/lib/input.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A valid confirmation must immediately explain the upcoming quiet work.
collect_inputs >"$test_root/input.stdout" 2>"$test_root/input.stderr" <<'INPUT'
buyer@example.com
licenca-nao-exibir
acme@example.com
app.example.com
api.example.com
portainer.example.com
SenhaForte!2026
SenhaForte!2026
INPUT
grep -Fq 'Preparando a instalacao' "$test_root/input.stderr" || fail 'aviso ausente apos confirmar senha'
grep -Fq 'Nao feche este terminal' "$test_root/input.stderr" || fail 'orientacao de espera ausente'
! grep -Eq 'SenhaForte|licenca-nao-exibir' "$test_root/input.stderr" || fail 'aviso expoe credencial'

console="$test_root/progress.stderr"
slow_step() {
  grep -Fq 'Instalando a stack do aplicativo' "$console" || return 71
  printf 'saida interna com licenca-nao-exibir\n'
  sleep 3
}
set +e
run_step deploy_app slow_step >"$test_root/progress.stdout" 2>"$console"
result=$?
set -e
[[ "$result" == 0 ]] || fail 'etapa nao mostrou seu nome antes de iniciar o trabalho'
[[ ! -s "$test_root/progress.stdout" ]] || fail 'progresso contaminou stdout'
grep -Eq '[0-9]+:[0-9]{2} decorridos' "$console" || fail 'etapa longa nao informa tempo decorrido'
grep -Fq 'Concluido:' "$console" || fail 'conclusao da etapa ausente'
! grep -Fq 'saida interna' "$console" || fail 'saida interna vazou no terminal'
! grep -Fq 'licenca-nao-exibir' "$LOG_FILE" || fail 'credencial vazou no log'
[[ "$(state_get deploy_app)" == completed ]] || fail 'estado de sucesso mudou'
[[ -z "$(jobs -pr)" ]] || fail 'monitor ficou em segundo plano apos sucesso'
size="$(wc -c < "$console")"
sleep 2
[[ "$(wc -c < "$console")" == "$size" ]] || fail 'progresso continuou apos concluir'

failing_step() { printf 'erro com licenca-nao-exibir\n'; sleep 2; return 42; }
set +e
run_step activation_and_download failing_step >"$test_root/failure.stdout" 2>"$test_root/failure.stderr"
result=$?
set -e
[[ "$result" == 42 ]] || fail 'codigo de erro nao foi preservado'
[[ "$(state_get activation_and_download)" == failed:42 ]] || fail 'estado de falha mudou'
grep -Fq '[REDACTED]' "$test_root/failure.stderr" || fail 'diagnostico redigido ausente'
! grep -Fq 'Concluido:' "$test_root/failure.stderr" || fail 'falha exibiu sucesso'
! grep -Fq 'licenca-nao-exibir' "$test_root/failure.stderr" || fail 'falha expoe credencial'
[[ -z "$(jobs -pr)" ]] || fail 'monitor ficou em segundo plano apos falha'

must_not_run() { touch "$test_root/executed-again"; }
run_step deploy_app must_not_run >"$test_root/skip.stdout" 2>"$test_root/skip.stderr"
[[ ! -e "$test_root/executed-again" ]] || fail 'retomada repetiu etapa concluida'
grep -Fq 'ja concluida' "$test_root/skip.stderr" || fail 'retomada nao explica etapa ignorada'
! grep -Fq 'decorridos' "$test_root/skip.stderr" || fail 'retomada iniciou monitor desnecessario'

# The normal 15-second heartbeat must not delay an instant step (including
# command substitution consumers, which wait for inherited output pipes).
unset INSTALLER_PROGRESS_INTERVAL
started=$SECONDS
instant_output="$(run_step verify true 2>&1)"
[[ "$((SECONDS - started))" -lt 3 ]] || fail 'monitor atrasou uma etapa instantanea'

# Use the real entrypoint ERR handler, not merely common.sh under set +e.
started=$SECONDS
set +e
production_output="$(bash -c '
  source "$1/install.sh"
  broken_step() { printf "erro com licenca-nao-exibir\n"; return 42; }
  register_secret licenca-nao-exibir
  run_step load_images broken_step
' _ "$repo_root" 2>&1)"
result=$?
set -e
[[ "$result" == 42 ]] || fail 'tratamento de erro real mudou o codigo'
[[ "$(state_get load_images)" == failed:42 ]] || fail 'tratamento de erro real pulou a finalizacao da etapa'
[[ "$((SECONDS - started))" -lt 3 ]] || fail 'monitor sobreviveu ao tratamento de erro real'
[[ "$production_output" != *licenca-nao-exibir* ]] || fail 'tratamento de erro real expoe segredo'
printf 'installer live progress: PASS\n'
