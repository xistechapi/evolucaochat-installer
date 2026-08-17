#!/usr/bin/env sh
set -eu

apk add --no-cache bash util-linux >/dev/null

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"

printf '%s\n' '#!/usr/bin/env sh' \
  'set -eu' \
  'output=""' \
  'last=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    --output) output="$2"; shift 2 ;;' \
  '    *) last="$1"; shift ;;' \
  '  esac' \
  'done' \
  'if [ -z "$output" ]; then' \
  '  tr -d "\r" < /repo/bootstrap.sh' \
  '  exit 0' \
  'fi' \
  'mkdir -p "$(dirname "$output")"' \
  'if [ "${last##*/}" = "install.sh" ]; then' \
  '  printf "%s\\n" "#!/usr/bin/env bash" "IFS= read -r buyer || { printf '\''missing buyer\\n'\'' >&2; exit 41; }" "printf '\''INPUT_CAPTURED=%s\\n'\'' \"\$buyer\"" > "$output"' \
  'else' \
  '  printf "fixture\\n" > "$output"' \
  'fi' \
  > "$test_root/bin/curl"
chmod 700 "$test_root/bin/curl"

set +e
output="$({ printf 'buyer@example.com\n'; } | script -qefc "export PATH=$test_root/bin:\$PATH; curl -fsSL https://raw.githubusercontent.com/xistechapi/evolucaochat-installer/main/bootstrap.sh | bash" /dev/null 2>&1)"
result=$?
set -e

case "$output" in
  *'INPUT_CAPTURED=buyer@example.com'*) ;;
  *)
    printf 'expected installer downloaded with curl pipe to read buyer input from terminal\n' >&2
    printf 'exit status: %s\n' "$result" >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

printf 'bootstrap stdin: PASS\n'
