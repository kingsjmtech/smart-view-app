#!/usr/bin/env bash
# ==============================================================================
# audit-container-capabilities.sh — report the effective security posture of
# every running service in the current compose project.
#
# Prints, per container: added capabilities, dropped capabilities, security
# options (no-new-privileges, seccomp, AppArmor), read-only rootfs, privileged
# flag, and the user the main process runs as — followed by a colored verdict
# (✔ hardened / ✘ NOT hardened) and a summary. Use it after changing
# cap_drop/cap_add/security_opt in docker-compose.deploy.yml to
# confirm the containers really run with what the file declares.
#
# Colors come from the shared scripts/colors.sh (also uploaded to the deploy
# server next to this script); output falls back to plain text when stdout is
# not a TTY or the lib is missing.
#
# Usage (server):  bash scripts/audit-container-capabilities.sh   # in the deploy dir
#
# Extra `docker compose` flags (e.g. -f compose.yml, --env-file .env) can be
# passed through: bash scripts/audit-container-capabilities.sh -f docker-compose.deploy.yml
# ==============================================================================
set -euo pipefail

for bin in docker jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "$bin is required" >&2
        exit 1
    fi
done

colors_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/colors.sh"
if [[ -f "$colors_lib" ]]; then
    # shellcheck source=colors.sh
    source "$colors_lib"
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

compose=(docker compose "$@")
status=0
services_total=0
containers_total=0
containers_failed=0

for service in $("${compose[@]}" ps --services); do
    containers=$("${compose[@]}" ps -q "$service" 2>/dev/null || true)
    services_total=$((services_total + 1))
    if [ -z "$containers" ]; then
        printf '%s=== Service: %s ===%s\n' "$BOLD$CYAN" "$service" "$RESET"
        printf '  %s(not running)%s\n\n' "$DIM" "$RESET"
        continue
    fi

    total=$(printf '%s\n' "$containers" | wc -l | tr -d ' ')
    replica=0
    while IFS= read -r cid; do
        if [ -z "$cid" ]; then
            continue
        fi
        replica=$((replica + 1))
        if [ "$total" -gt 1 ]; then
            printf '%s=== Service: %s (replica %s/%s) ===%s\n' "$BOLD$CYAN" "$service" "$replica" "$total" "$RESET"
        else
            printf '%s=== Service: %s ===%s\n' "$BOLD$CYAN" "$service" "$RESET"
        fi

        inspect=$(docker inspect "$cid")

        read_field() { printf '%s' "$inspect" | jq -r "$1"; }

        cap_add=$(read_field '.[0].HostConfig.CapAdd // [] | join(", ")')
        cap_drop=$(read_field '.[0].HostConfig.CapDrop // [] | join(", ")')
        sec_opt=$(read_field '.[0].HostConfig.SecurityOpt // [] | join(", ")')
        read_only=$(read_field '.[0].HostConfig.ReadonlyRootfs')
        privileged=$(read_field '.[0].HostConfig.Privileged')
        user=$(read_field '.[0].Config.User // ""')

        containers_total=$((containers_total + 1))

        printf '  %sCapabilities added:   %s%s\n' "$DIM" "$RESET" "${cap_add:-<none>}"
        if [ "$cap_drop" = "ALL" ]; then
            printf '  %sCapabilities dropped: %s%s%s%s\n' "$DIM" "$RESET" "$GREEN" "${cap_drop:-<none>}" "$RESET"
        else
            printf '  %sCapabilities dropped: %s%s%s%s\n' "$DIM" "$RESET" "$RED" "${cap_drop:-<none>}" "$RESET"
        fi
        printf '  %sSecurity options:     %s%s\n' "$DIM" "$RESET" "${sec_opt:-<none>}"
        printf '  %sRead-only rootfs:     %s%s\n' "$DIM" "$RESET" "$read_only"
        if [ "$privileged" = "true" ]; then
            printf '  %sPrivileged:           %s%s%s%s\n' "$DIM" "$RESET" "$RED" "$privileged" "$RESET"
        else
            printf '  %sPrivileged:           %s%s\n' "$DIM" "$RESET" "$privileged"
        fi
        if [ -z "$user" ] || [ "$user" = "root" ] || [ "$user" = "0" ]; then
            printf '  %sUser:                 %s%sroot (PID 1; services may still drop privileges themselves)%s\n' "$DIM" "$RESET" "$YELLOW" "$RESET"
        else
            printf '  %sUser:                 %s%s\n' "$DIM" "$RESET" "$user"
        fi

        findings=''
        if [ "$privileged" = "true" ]; then
            findings+='privileged — full host capabilities'
        fi
        if [ "$cap_drop" != "ALL" ]; then
            [ -n "$findings" ] && findings+='; '
            findings+='Docker default capability set in effect (cap_drop is not ALL)'
        fi

        if [ -n "$findings" ]; then
            printf '  %s✘ NOT hardened: %s%s\n\n' "$RED" "$findings" "$RESET"
            status=1
            containers_failed=$((containers_failed + 1))
        else
            printf '  %s✔ hardened%s\n\n' "$GREEN" "$RESET"
        fi
    done <<< "$containers"
done

printf '%s------------------------------------------------------------------------------%s\n' "$DIM" "$RESET"
printf 'Audited %s service(s), %s container(s).\n' "$services_total" "$containers_total"
if [ "$containers_failed" -gt 0 ]; then
    printf '%s✘ RESULT: FAIL — %s container(s) are not hardened (see ✘ lines above).%s\n' "$RED" "$containers_failed" "$RESET"
else
    printf '%s✔ RESULT: PASS — all containers drop ALL capabilities and none are privileged.%s\n' "$GREEN" "$RESET"
fi

exit $status
