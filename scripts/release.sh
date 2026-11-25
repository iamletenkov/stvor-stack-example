#!/bin/sh
# release.sh — сборка, проверка и публикация релиза стека-примера в Stvor. Одни и те же шаги вызывают
# .github/workflows/release.yml, .gitlab-ci.yml и человек при ручном выпуске (README, «Выпуск без CI»).
#
#   scripts/release.sh test               тесты api и web — стадия test Dockerfile, без сети
#   scripts/release.sh images             вход в реестр, buildx --push обеих архитектур, индексы в dist/
#   scripts/release.sh render             dist/<arch>/: compose.yaml, release.template.json, parameters.yaml, CHANGELOG.md
#   scripts/release.sh publish            ./stvor-stack-publish.sh по каждому варианту, ответы — dist/<arch>.response.json
#   scripts/release.sh all                test + images + render + publish (ручной выпуск)
#   scripts/release.sh local              сборка под свою архитектуру и запуск стека на этой машине, без реестра
#
# Окружение:
#   VERSION            SemVer без «v» (1.0.0); в CI — из тега v1.0.0
#   STVOR_URL          https://stvor.example.com — адрес портала; реестр — registry.<хост портала>[:порт]
#   STVOR_STACK        слаг стека — раздел реестра stacks/<слаг>/
#   STVOR_STACK_KEY    ключ стека sck_… (images, publish); только переменной окружения, не аргументом
#   RELEASE_COUNTER    release_counter (render): целое ≥ 1, общий для всех вариантов версии и растущий от версии
#                      к версии; STVOR_COUNTER_OFFSET (необязательно) прибавляется к нему
#   CREATED_AT         created_at (render), UTC 2026-11-22T10:00:00Z; по умолчанию — время коммита HEAD
#   SOURCE_REPO        https-адрес репозитория (render и метки образов); SOURCE_COMMIT — по умолчанию HEAD;
#                      SOURCE_PIPELINE — адрес pipeline или пусто (null)
#   PLATFORMS          linux/amd64,linux/arm64 (по умолчанию); вариант релиза = архитектура
#   DIST               каталог результатов, по умолчанию dist/ в корне репозитория
#
# Требуются: docker с buildx, jq, sha256sum (publish), curl (publish, local). Ключ не печатается и не попадает в argv:
# docker login получает его со stdin.
set -eu

PROG=release.sh
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SERVICES="api web"
DIST=${DIST:-$ROOT/dist}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
PUBLISH_SCRIPT=$ROOT/stvor-stack-publish.sh

NL='
'
SLUG_RE='^[a-z0-9][a-z0-9-]{1,39}$'
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
URL_RE='^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?/?$'
KEY_RE='^sck_[A-Za-z0-9_-]{16,128}={0,2}$'
TIME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() {
  say "$*"
  exit 2
}

matches() {
  case $1 in *"$NL"*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq -- "$2"
}

need_version() {
  VERSION=${VERSION:-}
  [ -n "$VERSION" ] || die "задайте VERSION (SemVer без «v», например 1.0.0)"
  matches "$VERSION" "$SEMVER_RE" || die "VERSION=$VERSION: ожидается SemVer без «v», например 1.0.0"
}

need_stack() {
  STVOR_STACK=${STVOR_STACK:-}
  matches "$STVOR_STACK" "$SLUG_RE" || die "STVOR_STACK: слаг стека — a-z, 0-9 и «-», 2…40 знаков"
}

need_url() {
  STVOR_URL=${STVOR_URL:-}
  matches "$STVOR_URL" "$URL_RE" || die "STVOR_URL: ожидается https://<домен>[:<порт>] без пути, строчными буквами"
  _hostport=${STVOR_URL#https://}
  REGISTRY=registry.${_hostport%/}
}

need_key() {
  STVOR_STACK_KEY=${STVOR_STACK_KEY:-}
  [ -n "$STVOR_STACK_KEY" ] || die "задайте ключ стека переменной окружения STVOR_STACK_KEY (в CI — masked-секрет)"
  matches "$STVOR_STACK_KEY" "$KEY_RE" || die "STVOR_STACK_KEY: это не ключ стека (ожидается sck_…)"
}

# Архитектуры из PLATFORMS: linux/amd64,linux/arm64 → amd64 arm64.
arches() {
  _out=
  for _p in $(printf '%s' "$PLATFORMS" | tr ',' ' '); do
    case $_p in
      linux/amd64 | linux/arm64) _out="$_out ${_p#linux/}" ;;
      *) die "PLATFORMS: поддерживаются linux/amd64 и linux/arm64, получено «$_p»" ;;
    esac
  done
  [ -n "$_out" ] || die "PLATFORMS пуст"
  printf '%s' "$_out"
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# ---------- test ----------

cmd_test() {
  for _svc in $SERVICES; do
    say "тесты $_svc (стадия test)"
    docker buildx build --target test --no-cache-filter test --output type=cacheonly "$ROOT/$_svc"
  done
}

# ---------- images ----------

# Сборка и push одного сервиса; при «blob unknown to registry» — один повтор той же командой.
push_image() {
  _svc=$1
  _ref=$REGISTRY/stacks/$STVOR_STACK/$_svc:$VERSION
  set -- --platform "$PLATFORMS" --provenance=mode=max --build-arg "DEMO_VERSION=$VERSION" \
    --label "org.opencontainers.image.version=$VERSION"
  if [ -n "${SOURCE_REPO:-}" ]; then set -- "$@" --label "org.opencontainers.image.source=$SOURCE_REPO"; fi
  if [ -n "${SOURCE_COMMIT:-}" ]; then set -- "$@" --label "org.opencontainers.image.revision=$SOURCE_COMMIT"; fi
  for _attempt in 1 2; do
    : >"$DIST/push-$_svc.status"
    { docker buildx build "$@" -t "$_ref" --push "$ROOT/$_svc" 2>&1 || echo $? >"$DIST/push-$_svc.status"; } \
      | tee "$DIST/push-$_svc.log"
    if [ ! -s "$DIST/push-$_svc.status" ]; then
      rm -f "$DIST/push-$_svc.status"
      return 0
    fi
    if [ "$_attempt" = 2 ] || ! grep -q 'blob unknown' "$DIST/push-$_svc.log"; then break; fi
    say "push $_svc: blob unknown to registry — один повтор"
  done
  die "push $_svc не удался (лог — $DIST/push-$_svc.log)"
}

cmd_images() {
  need_version
  need_stack
  need_url
  need_key
  arches >/dev/null
  mkdir -p "$DIST"
  printf '%s' "$STVOR_STACK_KEY" | docker login -u ci --password-stdin "$REGISTRY" >/dev/null
  trap 'docker logout "$REGISTRY" >/dev/null 2>&1 || true' EXIT
  for _svc in $SERVICES; do
    push_image "$_svc"
    # Индекс тега: из него render берёт digest манифеста каждой платформы. GET манифеста ключу стека разрешён.
    docker buildx imagetools inspect --raw "$REGISTRY/stacks/$STVOR_STACK/$_svc:$VERSION" >"$DIST/index-$_svc.json"
    say "образ $_svc:$VERSION отправлен, индекс — dist/index-$_svc.json"
  done
}

# ---------- render ----------

platform_digest() {
  jq -er --arg arch "$2" '
    [.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch)]
    | if length == 1 then .[0].digest else error("нет ровно одного манифеста linux/\($arch)") end
  ' "$1"
}

default_created_at() {
  _ts=$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null) || _ts=
  if [ -n "$_ts" ] && _t=$(date -u -d "@$_ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
    printf '%s' "$_t"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Проверка compose после подстановки — как его увидит docker compose на роботе (служебные переменные — фиктивные).
check_compose() {
  if ! docker compose version >/dev/null 2>&1; then
    say "docker compose нет — проверка compose.yaml пропущена"
    return 0
  fi
  env STACK_REGISTRY=registry.invalid STACK_SECRETS_DIR=/nonexistent STACK_DATA_DIR=/nonexistent \
    STACK_ROBOT_ID=check STACK_RELEASE="$STVOR_STACK@$VERSION" DEMO_ROBOT_LABEL=check \
    docker compose -p "stvor-$STVOR_STACK" -f "$1" config -q || die "docker compose config не принял $1"
}

cmd_render() {
  need_version
  need_stack
  _counter=${RELEASE_COUNTER:-}
  matches "$_counter" '^[1-9][0-9]{0,14}$' || die "RELEASE_COUNTER: целое ≥ 1 (в CI — номер pipeline)"
  _offset=${STVOR_COUNTER_OFFSET:-0}
  matches "$_offset" '^[0-9]{1,15}$' || die "STVOR_COUNTER_OFFSET: целое ≥ 0"
  _counter=$((_counter + _offset))
  _created=${CREATED_AT:-$(default_created_at)}
  # Время pipeline GitLab (CI_PIPELINE_CREATED_AT) — ISO 8601; иной вид (смещение, доли секунды) приводим к UTC.
  if ! matches "$_created" "$TIME_RE" && _norm=$(date -u -d "$_created" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
    _created=$_norm
  fi
  matches "$_created" "$TIME_RE" || die "CREATED_AT: ожидается UTC вида 2026-11-22T10:00:00Z"
  _repo=${SOURCE_REPO:-}
  [ -n "$_repo" ] || die "задайте SOURCE_REPO — https-адрес репозитория (source.repo релиза)"
  _commit=${SOURCE_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)}
  matches "$_commit" '^[0-9a-f]{7,64}$' || die "SOURCE_COMMIT: ожидается sha коммита"
  _pipeline=${SOURCE_PIPELINE:-}
  grep -qxF "## $VERSION" "$ROOT/CHANGELOG.md" \
    || grep -q "^## ${VERSION}[[:space:]]" "$ROOT/CHANGELOG.md" \
    || die "в CHANGELOG.md нет раздела «## $VERSION» — опишите версию до выпуска"

  for _arch in $(arches); do
    _out=$DIST/$_arch
    mkdir -p "$_out"
    # Готовый release.json скрипт публикации не переписывает — убираем след прошлой сборки.
    rm -f "$_out/release.json" "$_out/SHA256SUMS"
    set -- -e "s|__STACK__|$STVOR_STACK|g" -e "s|__VERSION__|$VERSION|g"
    _digests='{}'
    for _svc in $SERVICES; do
      [ -f "$DIST/index-$_svc.json" ] || die "нет $DIST/index-$_svc.json — сначала scripts/release.sh images"
      _digest=$(platform_digest "$DIST/index-$_svc.json" "$_arch") || die "индекс $_svc: нет манифеста linux/$_arch"
      matches "$_digest" "$DIGEST_RE" || die "индекс $_svc: digest linux/$_arch не sha256"
      _mark=$(upper "$_svc")
      set -- "$@" -e "s|__${_mark}_DIGEST__|$_digest|g"
      _digests=$(printf '%s' "$_digests" | jq -c --arg k "$_mark" --arg v "$_digest" '. + {($k): $v}')
    done
    sed "$@" "$ROOT/release/compose.release.yaml" >"$_out/compose.yaml"
    if grep -Eq '__[A-Z0-9_]+__' "$_out/compose.yaml"; then die "в $_out/compose.yaml остались маркеры"; fi
    check_compose "$_out/compose.yaml"
    # Заглушки __VARIANT__, __COMPOSE_DIGEST__ и __PARAMETERS_DIGEST__ заполнит stvor-stack-publish.sh.
    jq --arg stack "$STVOR_STACK" --arg version "$VERSION" --arg arch "$_arch" --arg created "$_created" \
      --arg repo "$_repo" --arg commit "$_commit" --arg pipeline "$_pipeline" \
      --argjson counter "$_counter" --argjson digests "$_digests" '
      def fill:
        gsub("__STACK__"; $stack) | gsub("__VERSION__"; $version) | gsub("__ARCH__"; $arch)
        | gsub("__CREATED_AT__"; $created) | gsub("__REPO__"; $repo) | gsub("__COMMIT__"; $commit)
        | reduce ($digests | to_entries[]) as $d (.; gsub("__\($d.key)_DIGEST__"; $d.value));
      walk(if type == "string" then fill else . end)
      | .release_counter = $counter
      | .source.pipeline = (if $pipeline == "" then null else $pipeline end)
    ' "$ROOT/release/release.template.json" >"$_out/release.template.json"
    cp "$ROOT/release/parameters.yaml" "$ROOT/CHANGELOG.md" "$_out/"
    say "вариант $_arch: $_out (release_counter $_counter, created_at $_created)"
  done
}

# ---------- publish ----------

cmd_publish() {
  need_version
  need_stack
  need_url
  need_key
  [ -f "$PUBLISH_SCRIPT" ] || die "нет stvor-stack-publish.sh в корне репозитория — скачайте его в портале: стек →" \
    "вкладка «Публикация» → «Скачать скрипт», и закоммитьте"
  for _arch in $(arches); do
    [ -d "$DIST/$_arch" ] || die "нет $DIST/$_arch — сначала scripts/release.sh render"
    say "публикация варианта $_arch"
    sh "$PUBLISH_SCRIPT" --url "$STVOR_URL" --stack "$STVOR_STACK" --version "$VERSION" --variant "$_arch" \
      --dir "$DIST/$_arch" >"$DIST/$_arch.response.json"
    cat "$DIST/$_arch.response.json"
  done
}

# ---------- local ----------

cmd_local() {
  VERSION=${VERSION:-0.0.0-local}
  need_version
  STVOR_STACK=${STVOR_STACK:-demo}
  need_stack
  _out=$DIST/local
  _project=stvor-$STVOR_STACK-local
  mkdir -p "$_out/secrets"
  set --
  for _svc in $SERVICES; do
    say "сборка $_svc для этой машины"
    docker buildx build --load --build-arg "DEMO_VERSION=$VERSION" -t "stvor-stack-example-$_svc:local" "$ROOT/$_svc"
    set -- "$@" -e "s|[$]{STACK_REGISTRY:?}/stacks/__STACK__/$_svc:__VERSION__@__$(upper "$_svc")_DIGEST__|stvor-stack-example-$_svc:local|"
  done
  sed "$@" "$ROOT/release/compose.release.yaml" >"$_out/compose.yaml"
  if grep -Eq '__[A-Z0-9_]+__' "$_out/compose.yaml"; then die "в $_out/compose.yaml остались маркеры"; fi
  # Фиктивный секрет: файл 0444, как его кладёт агент; значение случайное и никуда не выводится.
  if [ ! -s "$_out/secrets/api_token" ]; then
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n' >"$_out/secrets/api_token"
    chmod 0444 "$_out/secrets/api_token"
  fi
  cat >"$_out/stack.env" <<EOF
STACK_REGISTRY=registry.invalid
STACK_SECRETS_DIR=$_out/secrets
STACK_DATA_DIR=$_out/data
STACK_ROBOT_ID=local
STACK_RELEASE=$STVOR_STACK@$VERSION
DEMO_ROBOT_LABEL=${DEMO_ROBOT_LABEL:-local-robot}
DEMO_COLOR=${DEMO_COLOR:-blue}
EOF
  set -- docker compose -p "$_project" --env-file "$_out/stack.env" -f "$_out/compose.yaml"
  "$@" config -q
  "$@" up -d --wait --pull never --no-build
  say "стек запущен: http://127.0.0.1:18080/ (остановить: docker compose -p $_project -f dist/local/compose.yaml down)"
  if command -v curl >/dev/null 2>&1; then curl -fsS http://127.0.0.1:18080/ >/dev/null && say "страница отвечает 200"; fi
}

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  for _arg in "$@"; do
    case $_arg in *sck_*) die "ключ стека в аргументах не принимается — только переменная STVOR_STACK_KEY" ;; esac
  done
  [ "$#" -eq 1 ] || {
    usage >&2
    exit 2
  }
  case $1 in
    test) cmd_test ;;
    images) cmd_images ;;
    render) cmd_render ;;
    publish) cmd_publish ;;
    all)
      cmd_test
      cmd_images
      cmd_render
      cmd_publish
      ;;
    local) cmd_local ;;
    -h | --help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
