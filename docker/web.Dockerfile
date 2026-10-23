# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Production image for the slim-m web client: the release web bundle behind nginx.
#
# Built natively per architecture and merged into one manifest, like the server
# image (see .github/workflows/web-image.yml). The build id passed as SHA is
# compiled into the bundle and written to version.json, which is how an open
# tab learns a newer bundle is live (decision 0025).

FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS builder
ARG FLUTTER_VERSION=3.47.0
ARG SHA=dev
ARG SLIMM_SPOTIFY_CLIENT_ID=
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
RUN git config --global --add safe.directory /opt/flutter \
    && flutter config --no-analytics --enable-web \
    && flutter precache --web
WORKDIR /build
COPY client ./client
WORKDIR /build/client
RUN flutter pub get --enforce-lockfile
WORKDIR /build/client/packages/app
RUN bash tool/fetch_web_assets.sh \
    && flutter build web --release --base-href /app/ --pwa-strategy=none --no-web-resources-cdn \
        --dart-define=SLIMM_WEB_BUILD="${SHA}" \
        --dart-define=SLIMM_SPOTIFY_CLIENT_ID="${SLIMM_SPOTIFY_CLIENT_ID}" \
    && sed -i "s|flutter_bootstrap.js|flutter_bootstrap.js?v=${SHA}|" build/web/index.html \
    && sed -i "s|\"main.dart.js\"|\"main.dart.js?v=${SHA}\"|" build/web/flutter_bootstrap.js \
    && printf '{"build":"%s"}\n' "${SHA}" > build/web/version.json \
    && grep -q "main.dart.js?v=${SHA}" build/web/flutter_bootstrap.js \
    && grep -q "flutter_bootstrap.js?v=${SHA}" build/web/index.html

FROM nginxinc/nginx-unprivileged:1-alpine@sha256:26b0bf6fbf07297983cb341998d79c831508787de26627dd2a112321b9c3a4af
COPY docker/web-nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/web-security-headers.conf /etc/nginx/web-security-headers.conf
COPY --from=builder /build/client/packages/app/build/web /usr/share/nginx/html
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO /dev/null http://127.0.0.1:8080/version.json || exit 1
EXPOSE 8080
