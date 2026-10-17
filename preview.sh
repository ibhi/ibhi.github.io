#!/usr/bin/env bash
# Podman-based preview for the Hugo blog.
#
#   ./preview.sh dev       live-reloading Hugo server on http://localhost:1313 (drafts included)
#   ./preview.sh preview   production build (same flags as CI) served on http://localhost:8080 (no drafts)
#   ./preview.sh build     build the production preview image without starting it
#   ./preview.sh stop      stop and remove the preview containers
#   ./preview.sh shell     bash shell with hugo available and the site mounted at /site
#
# Ports can be changed with DEV_PORT / PREVIEW_PORT env vars.
set -euo pipefail
cd "$(dirname "$0")"

TOOLS_IMAGE="localhost/blog-hugo:latest"
PREVIEW_IMAGE="localhost/blog-preview:latest"
DEV_CONTAINER="blog-dev"
PREVIEW_CONTAINER="blog-preview"
DEV_PORT="${DEV_PORT:-1313}"
PREVIEW_PORT="${PREVIEW_PORT:-8080}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//;s/^#//'; }

rm_container() { podman rm -f -t 0 "$1" >/dev/null 2>&1 || true; }

build_tools() {
    say "Building Hugo tools image (cached after the first run)..."
    podman build --target tools -t "$TOOLS_IMAGE" .
}

wait_for_http() {
    command -v curl >/dev/null 2>&1 || return 0
    local url="$1" i status
    for i in 1 2 3 4 5; do
        status=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
        [ "$status" = "200" ] && { say "Serving $url (HTTP 200)"; return 0; }
        sleep 1
    done
    say "Container is up but $url returned '${status:-no response}' - check: podman logs $PREVIEW_CONTAINER"
}

case "${1:-}" in
    dev)
        build_tools
        rm_container "$DEV_CONTAINER"
        say "Starting live-reload dev server on http://localhost:${DEV_PORT}/ (Ctrl-C stops it)"
        exec podman run --rm -it --name "$DEV_CONTAINER" \
            -p "${DEV_PORT}:${DEV_PORT}" \
            -v "${PWD}:/site" -w /site \
            "$TOOLS_IMAGE" \
            hugo server --bind 0.0.0.0 --port "${DEV_PORT}" --buildDrafts
        ;;
    preview)
        say "Building production preview image (same Hugo version and flags as CI)..."
        podman build -t "$PREVIEW_IMAGE" .
        rm_container "$PREVIEW_CONTAINER"
        podman run -d --name "$PREVIEW_CONTAINER" \
            -p "${PREVIEW_PORT}:8080" \
            "$PREVIEW_IMAGE" >/dev/null
        wait_for_http "http://localhost:${PREVIEW_PORT}/"
        say "Open http://localhost:${PREVIEW_PORT}/ - stop with: ./preview.sh stop"
        ;;
    build)
        podman build -t "$PREVIEW_IMAGE" .
        say "Built ${PREVIEW_IMAGE}"
        ;;
    stop)
        rm_container "$DEV_CONTAINER"
        rm_container "$PREVIEW_CONTAINER"
        say "Preview containers stopped."
        ;;
    shell)
        build_tools
        podman run --rm -it \
            -v "${PWD}:/site" -w /site \
            --entrypoint /bin/bash \
            "$TOOLS_IMAGE"
        ;;
    *)
        usage
        exit 1
        ;;
esac
