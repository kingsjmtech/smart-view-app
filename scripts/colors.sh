#!/usr/bin/env bash
# shellcheck disable=SC2034  # color vars are consumed by the sourcing scripts
# ==============================================================================
# colors.sh — shared terminal-color library for smart-view-app shell scripts.
#
# Sourced (never executed) by scripts that print to the terminal:
#   scripts/audit-container-capabilities.sh
#   scripts/blue-green-deploy.sh
#
# The deploy workflows upload this file to the server next to
# blue-green-deploy.sh (see the scp step in .github/workflows/deploy-ssh-*.yml),
# so consumers source it relative to their own location and it resolves in both
# layouts:
#   repo  : scripts/colors.sh   (next to the consumer)
#   server: /home/docker/<app>-<env>/scripts/colors.sh
#
# Usage in a consumer:
#   source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"
#   printf '%sOK%s\n' "$GREEN" "$RESET"
#
# Colors are emitted only when stdout is a TTY — piped output (CI logs,
# redirects) stays clean. FORCE_COLOR=1 forces them on; NO_COLOR (no-color.org)
# or TERM=dumb forces them off.
# ==============================================================================

_kjm_use_color=0
if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
        _kjm_use_color=1
    fi
fi

if [[ "$_kjm_use_color" == "1" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# Ready-made output helpers for consumers that don't define their own.
# The lib_ prefix avoids collisions with consumer functions (log, die, ...).
lib_ok()   { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
lib_fail() { printf '%s✘%s %s\n' "$RED" "$RESET" "$*"; }
lib_warn() { printf '%s⚠%s %s\n' "$YELLOW" "$RESET" "$*"; }
lib_err()  { printf '%s✘%s %s\n' "$RED" "$RESET" "$*" >&2; }
lib_info() { printf '%s\n' "$*"; }
lib_head() { printf '%s%s%s\n' "$BOLD$CYAN" "$*" "$RESET"; }
