# Podman image for previewing the blog before it deploys to GitHub Pages.
#
# The toolchain mirrors .github/workflows/hugo.yaml (same Hugo, Dart Sass and
# TZ) and the build stage runs the exact same hugo command, so what you see
# locally is what production will serve.
#
# Stages:
#   tools    - hugo + dart-sass only, used for the live dev server and shells
#   builder  - builds the site into /site/public
#   runtime  - nginx serving the built site on port 8080

ARG HUGO_VERSION=0.153.1
ARG DART_SASS_VERSION=1.97.1

FROM docker.io/library/debian:bookworm-slim AS tools
ARG HUGO_VERSION
ARG DART_SASS_VERSION
ENV TZ=Europe/Oslo PATH="/opt/dart-sass:${PATH}"
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/hugo.tar.gz \
       "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.tar.gz" \
    && tar -C /usr/local/bin -xzf /tmp/hugo.tar.gz hugo \
    && curl -fsSL -o /tmp/dart-sass.tar.gz \
       "https://github.com/sass/dart-sass/releases/download/${DART_SASS_VERSION}/dart-sass-${DART_SASS_VERSION}-linux-x64.tar.gz" \
    && tar -C /opt -xzf /tmp/dart-sass.tar.gz \
    && rm -f /tmp/hugo.tar.gz /tmp/dart-sass.tar.gz \
    && hugo version \
    && sass --version

FROM tools AS builder
# Override with --build-arg SITE_BASE_URL=... when previewing under another host.
ARG SITE_BASE_URL=http://localhost:8080/
WORKDIR /site
COPY . .
RUN hugo --gc --minify --baseURL "${SITE_BASE_URL}"

FROM docker.io/nginxinc/nginx-unprivileged:1.27-alpine AS runtime
COPY --from=builder /site/public /usr/share/nginx/html
EXPOSE 8080
