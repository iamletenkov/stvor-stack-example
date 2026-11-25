# web стека-примера. Базовый образ закреплён по digest индекса (тег — для читателя); обновляйте оба вместе.
# Стадии build и test идут на платформе сборщика (BUILDPLATFORM), итоговая стадия без RUN — поэтому сборка
# linux/arm64 на amd64-раннере не требует эмуляции; QEMU в CI нужен, только если в runtime-стадии появится RUN.
ARG NODE_IMAGE=node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5

# Версия релиза запекается в build-config.json (CI передаёт --build-arg DEMO_VERSION=<версия>).
# hadolint ignore=DL3006
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS build
ARG DEMO_VERSION=0.0.0-dev
WORKDIR /out/app
COPY server.js build-config.json ./
RUN node -e 'require("fs").writeFileSync("build-config.json", JSON.stringify({version: process.argv[1]}))' "$DEMO_VERSION"

# Тесты — от пользователя приложения и без сети (CI: --target test до публикации образа).
FROM build AS test
WORKDIR /src
COPY . .
USER 10001:10001
RUN --network=none node --test

# Runtime: только программа и её конфиг, без тестов; запуск — не от root.
# hadolint ignore=DL3006
FROM ${NODE_IMAGE} AS runtime
ENV NODE_ENV=production
COPY --from=build /out/app /app
WORKDIR /app
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 CMD ["node", "/app/server.js", "--healthcheck"]
CMD ["node", "/app/server.js"]
