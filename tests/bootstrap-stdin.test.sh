#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"

MSYS_NO_PATHCONV=1 docker run --rm \
  --mount "type=bind,src=$repo_root,dst=/repo,readonly" \
  alpine:3.21 \
  sh /repo/tests/bootstrap-stdin-container.sh
