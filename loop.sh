#!/bin/bash
# Thin wrapper — all logic is in ccr loop
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ccr" loop "$@"
