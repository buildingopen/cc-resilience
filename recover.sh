#!/bin/bash
# Thin wrapper — all logic is in ccr recover
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ccr" recover "$@"
