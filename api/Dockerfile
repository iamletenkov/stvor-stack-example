# api стека-примера. Базовый образ закреплён по digest индекса (тег — для читателя); обновляйте оба вместе.
# Стадии build и test идут на платформе сборщика (BUILDPLATFORM), итоговая стадия без RUN — поэтому сборка
# linux/arm64 на amd64-раннере не требует эмуляции; QEMU в CI нужен, только если в runtime-стадии появится RUN.
ARG PYTHON_IMAGE=python:3.14-slim@sha256:22eafb370920ad8b429e0aec3fff433e0669968519f5d60469d83729c138b28b

# Версия релиза запекается в build-config.json (CI передаёт --build-arg DEMO_VERSION=<версия>). /data — 10001:10001,
# 0750: Docker переносит владельца и права каталога образа в пустой именованный том при первом подключении.
# hadolint ignore=DL3006
FROM --platform=$BUILDPLATFORM ${PYTHON_IMAGE} AS build
ARG DEMO_VERSION=0.0.0-dev
WORKDIR /out/app
COPY server.py build-config.json ./
RUN python3 -c 'import json, sys; json.dump({"version": sys.argv[1]}, open("build-config.json", "w"))' "$DEMO_VERSION" \
    && install -d -m 0750 /out/root/data

# Тесты — от пользователя приложения и без сети (CI: --target test до публикации образа).
FROM build AS test
WORKDIR /src
COPY . .
USER 10001:10001
RUN --network=none PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v

# Runtime: только программа и её конфиг, без тестов и инструментов сборки; запуск — не от root.
# hadolint ignore=DL3006
FROM ${PYTHON_IMAGE} AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY --from=build --chown=10001:10001 /out/root/ /
COPY --from=build /out/app /app
WORKDIR /app
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 CMD ["python3", "/app/server.py", "--healthcheck"]
CMD ["python3", "/app/server.py"]
