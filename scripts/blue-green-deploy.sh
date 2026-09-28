#!/usr/bin/env bash
# ==============================================================================
# blue-green-deploy.sh — zero-downtime deploys for smart-view-app.
#
# Runs on the deploy server from /home/docker/smart-view-app-<env>/ (uploaded there by
# .github/workflows/deploy-ssh-*.yml next to .env and docker-compose.deploy.yml).
#
# Two identical web slots (web-blue / web-green) run side by side. A deploy
# starts the idle slot on the new image, runs the release steps, waits for it
# to become healthy, then flips live traffic by rewriting a Traefik
# file-provider route:
#
#   /home/docker/traefik/dynamic/smart-view-app-<env>.yml   (watched by Traefik)
#
# The route is a failover service: primary = new slot, fallback = previous
# slot, so a crash of the new slot fails back automatically. The previous slot
# keeps running (pinned to its old image tag) until the next deploy, which
# makes `rollback` an instant flip.
#
# The docker labels on both slots declare a low-priority router for the same
# host, so the site still resolves if the dynamic file is missing.
#
# Usage:
#   bash scripts/blue-green-deploy.sh deploy     # full blue-green deploy
#   bash scripts/blue-green-deploy.sh rollback   # flip back to the previous slot
#   bash scripts/blue-green-deploy.sh status     # show slots + active color
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$DEPLOY_DIR"

if [[ -f "$SCRIPT_DIR/colors.sh" ]]; then
    # shellcheck source=colors.sh
    source "$SCRIPT_DIR/colors.sh"
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ---------------------------------------------------------------------------
# Per-app settings
# ---------------------------------------------------------------------------
ENV_PREFIX="SMART_VIEW_APP_"
APP_PORT="${APP_PORT:-80}"
HEALTH_PATH="${HEALTH_PATH:-/up}"
# Expected status when HEALTH_PATH is not a public 2xx endpoint (e.g. API-key protected)
HEALTH_STATUS="${HEALTH_STATUS:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
SITE_TIMEOUT="${SITE_TIMEOUT:-90}"

ENV_FILE="$DEPLOY_DIR/.env"
COMPOSE_FILE="$DEPLOY_DIR/compose.yml"
STATE_FILE="$DEPLOY_DIR/.active-deploy-color"

log()  { printf '%s[%s]%s %s\n' "$DIM" "$(date '+%H:%M:%S')" "$RESET" "$*"; }
ok()   { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s⚠%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s✘%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
head_() { printf '\n%s==> %s%s\n' "$BOLD$CYAN" "$*" "$RESET"; }

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing $COMPOSE_FILE"

# Read KEY from .env without sourcing it (values may contain shell syntax).
env_get() {
    local key="$1" line value
    line=$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    printf '%s' "$value"
}

# Replace (or append) KEY=VALUE in .env.
env_set() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp "$DEPLOY_DIR/.env.XXXXXX")
    grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
}

CONTAINER_NAME="$(env_get "${ENV_PREFIX}DOCKER_CONTAINER_NAME")"
IMAGE_NAME="$(env_get "${ENV_PREFIX}DOCKER_IMAGE_NAME")"
IMAGE_TAG="$(env_get "${ENV_PREFIX}DOCKER_IMAGE_TAG")"
APP_DOMAIN="$(env_get "${ENV_PREFIX}APP_DOMAIN")"
TRAEFIK_DYNAMIC_DIR="$(env_get "${ENV_PREFIX}TRAEFIK_DYNAMIC_DIR")"
TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-/home/docker/traefik/dynamic}"
TRAEFIK_CERT_RESOLVER="$(env_get "${ENV_PREFIX}TRAEFIK_CERT_RESOLVER")"
TRAEFIK_CERT_RESOLVER="${TRAEFIK_CERT_RESOLVER:-letsencrypt}"
STORAGE_PATH="$(env_get "${ENV_PREFIX}DOCKER_STORAGE_VOLUME_PATH")"
STORAGE_PATH="${STORAGE_PATH:-$DEPLOY_DIR/storage}"

[[ -n "$CONTAINER_NAME" ]] || die "${ENV_PREFIX}DOCKER_CONTAINER_NAME is not set in .env"
[[ -n "$IMAGE_NAME" ]] || die "${ENV_PREFIX}DOCKER_IMAGE_NAME is not set in .env"
[[ -n "$APP_DOMAIN" ]] || die "${ENV_PREFIX}APP_DOMAIN is not set in .env"

ROUTE_FILE="$TRAEFIK_DYNAMIC_DIR/${CONTAINER_NAME}.yml"

compose() {
    docker compose --project-name "$CONTAINER_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

slot_container() { printf '%s-web-%s' "$CONTAINER_NAME" "$1"; }
other_color() { [[ "$1" == "blue" ]] && echo green || echo blue; }

active_color() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo blue
    fi
}

slot_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$(slot_container "$1")" 2>/dev/null || echo false)" == "true" ]]
}

slot_health() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(slot_container "$1")" 2>/dev/null || echo missing
}

wait_healthy() {
    local color="$1" waited=0 status
    log "Waiting for web-$color to become healthy (timeout ${HEALTH_TIMEOUT}s)..."
    while (( waited < HEALTH_TIMEOUT )); do
        status=$(slot_health "$color")
        case "$status" in
            healthy|none) ok "web-$color is $status"; return 0 ;;
            unhealthy) break ;;
        esac
        sleep 3
        waited=$((waited + 3))
    done
    compose logs --tail=80 "web-$color" || true
    return 1
}

# ---------------------------------------------------------------------------
# App-specific hooks
# ---------------------------------------------------------------------------
# Laravel: host storage is bind-mounted into every container, so make sure the
# framework directories exist before the first boot.
prepare_storage() {
    mkdir -p \
        "$STORAGE_PATH/app/public" \
        "$STORAGE_PATH/framework/cache/data" \
        "$STORAGE_PATH/framework/sessions" \
        "$STORAGE_PATH/framework/testing" \
        "$STORAGE_PATH/framework/views" \
        "$STORAGE_PATH/logs"
}

artisan() {
    local color="$1"
    shift
    compose exec -T "web-$color" php artisan "$@"
}

release_steps() {
    local color="$1"
    log "Fixing storage ownership in web-$color..."
    compose exec -T -u root "web-$color" chown -R application:application storage bootstrap/cache || return 1
    log "Running migrations..."
    artisan "$color" migrate --force || return 1
    log "Seeding (idempotent seeders)..."
    artisan "$color" db:seed --force || return 1
    log "Caching config/routes/events..."
    artisan "$color" config:cache || return 1
    artisan "$color" route:cache || return 1
    artisan "$color" event:cache || return 1
    if compose exec -T "web-$color" test -d resources/views; then
        artisan "$color" view:cache || return 1
    fi
}

post_flip_steps() {
    local color="$1"
    artisan "$color" queue:restart || true
}

rollback_prepare() {
    return 1
}

# ---------------------------------------------------------------------------
# Traefik route
# ---------------------------------------------------------------------------
write_route() {
    local primary="$1" fallback="${2:-}" tmp live_service
    [[ -d "$TRAEFIK_DYNAMIC_DIR" ]] || die "Traefik dynamic dir $TRAEFIK_DYNAMIC_DIR does not exist"
    tmp=$(mktemp "$TRAEFIK_DYNAMIC_DIR/.${CONTAINER_NAME}.XXXXXX")

    if [[ -n "$fallback" ]]; then
        live_service="${CONTAINER_NAME}-live"
    else
        live_service="${CONTAINER_NAME}-${primary}"
    fi

    # shellcheck disable=SC2016 # backticks are literal Traefik rule syntax
    {
        printf '# Managed by scripts/blue-green-deploy.sh — active color: %s\n' "$primary"
        printf 'http:\n'
        printf '  routers:\n'
        printf '    %s-live:\n' "$CONTAINER_NAME"
        printf '      rule: "Host(`%s`)"\n' "$APP_DOMAIN"
        printf '      entryPoints: [websecure]\n'
        printf '      priority: 10000\n'
        printf '      service: %s\n' "$live_service"
        printf '      tls:\n'
        printf '        certResolver: %s\n' "$TRAEFIK_CERT_RESOLVER"
        printf '    %s-live-http:\n' "$CONTAINER_NAME"
        printf '      rule: "Host(`%s`)"\n' "$APP_DOMAIN"
        printf '      entryPoints: [web]\n'
        printf '      priority: 10000\n'
        printf '      middlewares: [%s-https-redirect]\n' "$CONTAINER_NAME"
        printf '      service: %s\n' "$live_service"
        printf '  middlewares:\n'
        printf '    %s-https-redirect:\n' "$CONTAINER_NAME"
        printf '      redirectScheme:\n'
        printf '        scheme: https\n'
        printf '        permanent: true\n'
        printf '  services:\n'
        if [[ -n "$fallback" ]]; then
            printf '    %s-live:\n' "$CONTAINER_NAME"
            printf '      failover:\n'
            printf '        service: %s-%s\n' "$CONTAINER_NAME" "$primary"
            printf '        fallback: %s-%s\n' "$CONTAINER_NAME" "$fallback"
        fi
        local color
        for color in $primary $fallback; do
            printf '    %s-%s:\n' "$CONTAINER_NAME" "$color"
            printf '      loadBalancer:\n'
            printf '        passHostHeader: true\n'
            printf '        servers:\n'
            printf '          - url: "http://%s:%s"\n' "$(slot_container "$color")" "$APP_PORT"
            printf '        healthCheck:\n'
            printf '          path: "%s"\n' "$HEALTH_PATH"
            printf '          hostname: "%s"\n' "$APP_DOMAIN"
            printf '          interval: 5s\n'
            printf '          timeout: 3s\n'
            if [[ -n "$HEALTH_STATUS" ]]; then
                printf '          status: %s\n' "$HEALTH_STATUS"
            fi
        done
    } > "$tmp"

    chmod 644 "$tmp"
    mv -f "$tmp" "$ROUTE_FILE"
    printf '%s\n' "$primary" > "$STATE_FILE"
    ok "Traefik route → web-$primary${fallback:+ (fallback web-$fallback)}"
}

# Verify the public route through the local Traefik entrypoint. -k because a
# brand-new host may still be waiting for its ACME certificate.
wait_site_up() {
    local waited=0 code
    log "Checking https://${APP_DOMAIN}${HEALTH_PATH} via local Traefik (timeout ${SITE_TIMEOUT}s)..."
    while (( waited < SITE_TIMEOUT )); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
            --resolve "${APP_DOMAIN}:443:127.0.0.1" "https://${APP_DOMAIN}${HEALTH_PATH}" || true)
        if [[ "$code" =~ ^[23][0-9][0-9]$ || ( -n "$HEALTH_STATUS" && "$code" == "$HEALTH_STATUS" ) ]]; then
            ok "Site responded with HTTP $code"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    warn "Site did not respond with 2xx/3xx (last: ${code:-none})"
    return 1
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_deploy() {
    [[ -n "$IMAGE_TAG" ]] || die "${ENV_PREFIX}DOCKER_IMAGE_TAG is not set in .env"

    local active new previous=""
    active=$(active_color)
    new=$(other_color "$active")
    if slot_running "$active"; then
        previous="$active"
    else
        # Nothing live (first deploy or slot died) — take the active slot itself.
        new="$active"
    fi

    head_ "Deploying $IMAGE_NAME:$IMAGE_TAG to web-$new${previous:+ (live: web-$previous)}"

    mkdir -p "$STORAGE_PATH"
    prepare_storage

    # Pin the live slot to the tag it is running so `compose up` never
    # recreates it; the new slot gets the new tag.
    if [[ -n "$previous" ]]; then
        local live_tag
        live_tag=$(docker inspect -f '{{.Config.Image}}' "$(slot_container "$previous")")
        env_set "${ENV_PREFIX}DOCKER_IMAGE_TAG_${previous^^}" "${live_tag##*:}"
    fi
    env_set "${ENV_PREFIX}DOCKER_IMAGE_TAG_${new^^}" "$IMAGE_TAG"

    log "Pulling images..."
    compose pull --policy missing "web-$new"

    log "Starting web-$new..."
    compose up -d --no-deps --force-recreate "web-$new"

    if ! release_steps "$new"; then
        compose stop "web-$new" || true
        die "Release steps failed on web-$new — live traffic untouched"
    fi

    if ! wait_healthy "$new"; then
        compose stop "web-$new" || true
        die "web-$new failed its health check — live traffic untouched"
    fi

    write_route "$new" "$previous"

    if ! wait_site_up; then
        if [[ -n "$previous" ]]; then
            write_route "$previous" "$new"
            die "New slot not reachable through Traefik — reverted route to web-$previous"
        fi
        die "Site not reachable through Traefik after first deploy — check DNS/Traefik"
    fi

    post_flip_steps "$new"

    local others
    others=$(compose config --services | grep -v '^web-' || true)
    if [[ -n "$others" ]]; then
        log "Recreating supporting services on the new image..."
        # shellcheck disable=SC2086
        compose up -d --no-deps --remove-orphans $others
    fi

    ok "Deploy complete: web-$new is live on $IMAGE_TAG"
}

cmd_rollback() {
    local active target
    active=$(active_color)
    target=$(other_color "$active")
    if ! slot_running "$target"; then
        rollback_prepare "$target" || die "web-$target is not running — nothing to roll back to"
    fi
    wait_healthy "$target" || die "web-$target is not healthy — refusing to roll back"
    write_route "$target" "$active"
    wait_site_up || warn "Rolled back, but the site check did not pass"
    post_flip_steps "$target"
    ok "Rolled back: web-$target is live"
}

cmd_status() {
    local active color
    active=$(active_color)
    head_ "$CONTAINER_NAME ($APP_DOMAIN)"
    for color in blue green; do
        local marker=""
        [[ "$color" == "$active" ]] && marker=" ${GREEN}← live${RESET}"
        if slot_running "$color"; then
            printf '  web-%-5s running  %s  health=%s%s\n' "$color" \
                "$(docker inspect -f '{{.Config.Image}}' "$(slot_container "$color")")" "$(slot_health "$color")" "$marker"
        else
            printf '  web-%-5s stopped%s\n' "$color" "$marker"
        fi
    done
    compose ps
}

case "${1:-}" in
    deploy) cmd_deploy ;;
    rollback) cmd_rollback ;;
    status) cmd_status ;;
    *) echo "Usage: $0 {deploy|rollback|status}" >&2; exit 1 ;;
esac
