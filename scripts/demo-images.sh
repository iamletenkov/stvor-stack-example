#!/bin/sh
# demo-images.sh — образы примера в GHCR: api, web и пакет релиза версий 1.0.0, 1.1.0, 1.2.0 для проверок,
# которым нужен настоящий стек (гейт робота в Stvor). Запускает .github/workflows/demo-images.yml вручную.
#
#   scripts/demo-images.sh --self-test    проверки скрипта без Docker и сети
#   scripts/demo-images.sh build          тесты (scripts/release.sh test) и сборка трёх версий без отправки
#   scripts/demo-images.sh build --push   то же и отправка в реестр; существующий тег не перезаписывается
#   scripts/demo-images.sh lock           таблица digest в stdout: version, component, platform, digest, source_commit
#
# Версии собираются из одного коммита: 1.0.0 — дерево коммита, 1.1.0 и 1.2.0 — с demo/1.1.0.patch и затем
# demo/1.2.0.patch поверх (накопительно, во временной копии; рабочее дерево не меняется). Тег образа —
# demo-<версия>-<первые 12 знаков коммита>; робот и проверки берут образ только по digest.
#
# Окружение:
#   IMAGE_PREFIX   реестр и путь, по умолчанию ghcr.io/iamletenkov/stvor-stack-example → …/{api,web,release}
#   PLATFORMS      linux/amd64,linux/arm64 (по умолчанию) — платформы сборки и проверки индекса в lock
#   LOCK_PLATFORMS платформы строк таблицы lock, по умолчанию = PLATFORMS (по строке на каждую платформу)
#   SOURCE_REPO    https-адрес репозитория для меток образа, по умолчанию https://github.com/<путь IMAGE_PREFIX>
#
# Требуются: git, patch, jq; для build и lock — docker с buildx (builder с драйвером docker-container для
# нескольких платформ). Вход в реестр делает вызывающий (workflow — встроенным GITHUB_TOKEN).
set -eu

PROG=demo-images.sh
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
VERSIONS="1.0.0 1.1.0 1.2.0"
COMPONENTS="api web release"
IMAGE_PREFIX=${IMAGE_PREFIX:-ghcr.io/iamletenkov/stvor-stack-example}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
LOCK_PLATFORMS=${LOCK_PLATFORMS:-$PLATFORMS}

NL='
'
TAB=$(printf '\t')
DIGEST_RE='^sha256:[0-9a-f]{64}$'
COMMIT_RE='^[0-9a-f]{40}$'
PREFIX_RE='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]([a-z0-9._-]*[a-z0-9])?)+$'
PLATFORM_RE='^linux/(amd64|arm64)$'
# Ответ реестра «нет такого тега или репозитория»; любой другой отказ — ошибка, а не «тега нет».
ABSENT_RE='not found|manifest unknown|MANIFEST_UNKNOWN|name unknown|NAME_UNKNOWN'

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() {
  say "$*"
  exit 2
}

matches() {
  case $1 in *"$NL"*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq -- "$2"
}

# ---------- чистые функции ----------

in_list() {
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# Патчи demo/ для версии — накопительно от первой версии из VERSIONS: 1.2.0 → demo/1.1.0.patch demo/1.2.0.patch.
patches_for() {
  in_list "${1:-}" "$VERSIONS" || die "версия «${1:-}» не из набора: $VERSIONS"
  _pf_out=
  _pf_first=1
  for _pf_v in $VERSIONS; do
    if [ "$_pf_first" = 1 ]; then _pf_first=0; else _pf_out="${_pf_out:+$_pf_out }demo/$_pf_v.patch"; fi
    [ "$_pf_v" != "$1" ] || break
  done
  printf '%s' "$_pf_out"
}

source_commit() {
  _sc=$(git -C "$ROOT" rev-parse HEAD) || die "нет коммита HEAD: собирается только закоммиченное дерево"
  matches "$_sc" "$COMMIT_RE" || die "HEAD: ожидается sha1 коммита, получено «$_sc»"
  printf '%s' "$_sc"
}

# demo-<версия>-<12 знаков коммита>: неизменяемый тег, один на версию и коммит.
image_tag() {
  in_list "${1:-}" "$VERSIONS" || die "версия «${1:-}» не из набора: $VERSIONS"
  matches "${2:-}" "$COMMIT_RE" || die "коммит «${2:-}»: ожидается полный sha1"
  printf 'demo-%s-%.12s' "$1" "$2"
}

image_ref() {
  in_list "${1:-}" "$COMPONENTS" || die "компонент «${1:-}» не из набора: $COMPONENTS"
  matches "$IMAGE_PREFIX" "$PREFIX_RE" || die "IMAGE_PREFIX=$IMAGE_PREFIX: ожидается <реестр>/<путь> строчными буквами"
  _ir_tag=$(image_tag "${2:-}" "${3:-}")
  printf '%s/%s:%s' "$IMAGE_PREFIX" "$1" "$_ir_tag"
}

platform_list() {
  _pl_out=
  for _pl in $(printf '%s' "$1" | tr ',' ' '); do
    matches "$_pl" "$PLATFORM_RE" || die "платформа «$_pl»: поддерживаются linux/amd64 и linux/arm64"
    _pl_out="${_pl_out:+$_pl_out }$_pl"
  done
  [ -n "$_pl_out" ] || die "пустой список платформ"
  printf '%s' "$_pl_out"
}

# digest манифеста платформы из индекса: ровно один манифест linux/<arch>, только sha256.
platform_digest() {
  _pd=$(printf '%s' "$1" | jq -er --arg os "${2%%/*}" --arg arch "${2#*/}" '
    [.manifests[] | select(.platform.os == $os and .platform.architecture == $arch)]
    | if length == 1 then .[0].digest else error("манифестов \($os)/\($arch): \(length)") end
  ' 2>/dev/null) || return 1
  matches "$_pd" "$DIGEST_RE" || return 1
  printf '%s' "$_pd"
}

# Строки lock одного компонента версии из индекса (stdin): по строке на платформу LOCK_PLATFORMS. Каждая платформа
# PLATFORMS обязана быть в индексе.
lock_rows() {
  [ "$#" -eq 3 ] || die "lock_rows <версия> <компонент> <коммит>"
  in_list "$2" "$COMPONENTS" || die "компонент «$2» не из набора: $COMPONENTS"
  _lr_tag=$(image_tag "$1" "$3")
  _lr_idx=$(cat)
  printf '%s' "$_lr_idx" | jq -e '.manifests | type == "array"' >/dev/null 2>&1 \
    || die "$2:$_lr_tag: ответ реестра — не индекс OCI"
  _lr_all=$(platform_list "$PLATFORMS")
  for _lr_p in $_lr_all; do
    platform_digest "$_lr_idx" "$_lr_p" >/dev/null \
      || die "$2:$_lr_tag: в индексе нет ровно одного манифеста $_lr_p с digest sha256"
  done
  _lr_lock=$(platform_list "$LOCK_PLATFORMS")
  for _lr_p in $_lr_lock; do
    in_list "$_lr_p" "$_lr_all" || die "LOCK_PLATFORMS: $_lr_p нет в PLATFORMS"
    _lr_d=$(platform_digest "$_lr_idx" "$_lr_p") || die "$2:$_lr_tag: нет манифеста $_lr_p"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$_lr_p" "$_lr_d" "$3"
  done
}

# exists | absent; при другом ответе реестра (вход, сеть) — отказ, а не «тега нет».
tag_state() {
  [ "$#" -eq 1 ] || die "tag_state <ссылка>"
  if _ts_err=$(docker buildx imagetools inspect --raw "$1" 2>&1 >/dev/null); then
    echo exists
  elif printf '%s' "$_ts_err" | grep -Eq -- "$ABSENT_RE"; then
    echo absent
  else
    die "реестр не ответил про $1: $(printf '%s' "$_ts_err" | tail -n 1)"
  fi
}

# Сборка одного компонента версии из подготовленного дерева; $5 = 1 — отправка в реестр.
build_one() {
  _bo_comp=$1
  _bo_v=$2
  _bo_tree=$3
  _bo_commit=$4
  _bo_push=$5
  _bo_ref=$(image_ref "$_bo_comp" "$_bo_v" "$_bo_commit")
  _bo_src=${SOURCE_REPO:-https://github.com/${IMAGE_PREFIX#*/}}
  set -- --platform "$PLATFORMS" --provenance=mode=max --build-arg "DEMO_VERSION=$_bo_v" \
    --label "org.opencontainers.image.title=stvor-stack-example $_bo_comp" \
    --label "org.opencontainers.image.version=$_bo_v" \
    --label "org.opencontainers.image.source=$_bo_src" \
    --label "org.opencontainers.image.revision=$_bo_commit" \
    --label "org.opencontainers.image.licenses=MIT"
  if [ "$_bo_push" = 1 ]; then
    # Аннотации индекса читает страница пакета GHCR (связь с репозиторием, описание).
    set -- "$@" \
      --annotation "index:org.opencontainers.image.source=$_bo_src" \
      --annotation "index:org.opencontainers.image.revision=$_bo_commit" \
      --annotation "index:org.opencontainers.image.version=$_bo_v" \
      --annotation "index:org.opencontainers.image.licenses=MIT" \
      --annotation "index:org.opencontainers.image.description=stvor-stack-example $_bo_comp $_bo_v: demo image, pull by digest" \
      --output "type=image,name=$_bo_ref,push=true,oci-mediatypes=true,rewrite-timestamp=true"
    say "сборка $_bo_comp $_bo_v ($PLATFORMS) → $_bo_ref"
  else
    set -- "$@" --output type=cacheonly
    say "сборка $_bo_comp $_bo_v ($PLATFORMS), без отправки"
  fi
  case $_bo_comp in
    release) set -- "$@" -f "$_bo_tree/release/Dockerfile.bundle" "$_bo_tree" ;;
    *) set -- "$@" "$_bo_tree/$_bo_comp" ;;
  esac
  docker buildx build "$@"
}

cmd_build() {
  _b_push=0
  case ${1:-} in
    --push)
      _b_push=1
      shift
      ;;
    "") ;;
    *) die "build [--push]" ;;
  esac
  [ "$#" -eq 0 ] || die "build [--push]"
  _b_platforms=$(platform_list "$PLATFORMS")
  _b_commit=$(source_commit)
  _b_epoch=$(git -C "$ROOT" log -1 --format=%ct HEAD)
  matches "$_b_epoch" '^[0-9]{1,12}$' || die "время коммита HEAD не прочитано"
  if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    say "в рабочем дереве есть правки — они не войдут: собирается коммит $_b_commit"
  fi

  # Все девять тегов проверяются до первой сборки: частичной перезаписи не бывает.
  if [ "$_b_push" = 1 ]; then
    _b_taken=
    for _b_v in $VERSIONS; do
      for _b_c in $COMPONENTS; do
        _b_ref=$(image_ref "$_b_c" "$_b_v" "$_b_commit")
        _b_state=$(tag_state "$_b_ref")
        [ "$_b_state" = absent ] || _b_taken="$_b_taken $_b_ref"
      done
    done
    [ -z "$_b_taken" ] || die "тег уже есть:$_b_taken — не перезаписываю; новая сборка — новый коммит"
  fi

  "$ROOT/scripts/release.sh" test

  # Время файлов и образа — время коммита: те же исходники дают те же слои.
  SOURCE_DATE_EPOCH=$_b_epoch
  export SOURCE_DATE_EPOCH
  _b_tree=$(mktemp -d)
  trap 'rm -rf "$_b_tree"' EXIT
  git -C "$ROOT" archive HEAD | tar -x -C "$_b_tree"
  for _b_v in $VERSIONS; do
    _b_last=$(patches_for "$_b_v" | tr ' ' '\n' | tail -n 1)
    if [ -n "$_b_last" ]; then
      say "версия $_b_v: $_b_last"
      patch -d "$_b_tree" -p1 -N -s --fuzz=0 --no-backup-if-mismatch -i "$_b_tree/$_b_last" \
        || die "$_b_last не применяется к дереву $_b_commit"
    fi
    grep -qxF "## $_b_v" "$_b_tree/CHANGELOG.md" || die "версия $_b_v: в CHANGELOG.md нет раздела «## $_b_v»"
    for _b_c in $COMPONENTS; do
      build_one "$_b_c" "$_b_v" "$_b_tree" "$_b_commit" "$_b_push"
    done
  done
  say "готово: версии $VERSIONS × $COMPONENTS, платформы $_b_platforms"
}

cmd_lock() {
  [ "$#" -eq 0 ] || die "lock без аргументов"
  _l_commit=$(source_commit)
  for _l_v in $VERSIONS; do
    for _l_c in $COMPONENTS; do
      _l_ref=$(image_ref "$_l_c" "$_l_v" "$_l_commit")
      _l_idx=$(docker buildx imagetools inspect --raw "$_l_ref") || die "нет $_l_ref — сначала build --push"
      printf '%s' "$_l_idx" | lock_rows "$_l_v" "$_l_c" "$_l_commit"
    done
  done
}

# ---------- self-test ----------

ST_FAIL=0
st_ok() { printf 'ok   %s\n' "$1"; }
st_bad() {
  printf 'FAIL %s\n' "$1"
  ST_FAIL=1
}
st_eq() {
  if [ "$2" = "$3" ]; then st_ok "$1"; else st_bad "$1: ожидалось «$3», получено «$2»"; fi
}
# Команда в подоболочке должна упасть.
st_refuses() {
  _name=$1
  shift
  if ("$@") >/dev/null 2>&1; then st_bad "$_name: не отказал"; else st_ok "$_name"; fi
}

st_index() {
  # $1 — digest amd64, $2 — digest arm64 (пусто — нет платформы), $3 — лишний amd64 (пусто — нет)
  _m="{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"$1\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}}"
  if [ -n "$2" ]; then
    _m="$_m,{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"$2\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\"}}"
  fi
  if [ -n "${3:-}" ]; then
    _m="$_m,{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"$3\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}}"
  fi
  # Аттестация buildx — манифест с платформой unknown/unknown, в таблицу не попадает.
  _att="{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:$(printf '%064d' 9)\",\"platform\":{\"os\":\"unknown\",\"architecture\":\"unknown\"},\"annotations\":{\"vnd.docker.reference.type\":\"attestation-manifest\"}}"
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s,%s]}' "$_m" "$_att"
}

# Подменный docker: imagetools inspect отвечает по ST_DOCKER_MODE, вызовы — в журнал.
st_fake_docker() {
  _bin=$1
  mkdir -p "$_bin"
  cat >"$_bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$ST_DOCKER_LOG"
case "$*" in
  "buildx imagetools inspect"*)
    case $ST_DOCKER_MODE in
      exists) printf '{"schemaVersion":2}\n'; exit 0 ;;
      absent) echo 'ERROR: ghcr.io/x/y:z: not found' >&2; exit 1 ;;
      denied) echo 'ERROR: unexpected status from HEAD request: 401 Unauthorized' >&2; exit 1 ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$_bin/docker"
}

self_test() {
  _tmp=$(mktemp -d)
  trap 'rm -rf "$_tmp"' EXIT
  _c=0123456789abcdef0123456789abcdef01234567
  _d1=sha256:$(printf '%064d' 1 | tr 0 a)
  _d2=sha256:$(printf '%064d' 2 | tr 0 b)

  st_eq "версии" "$VERSIONS" "1.0.0 1.1.0 1.2.0"
  st_eq "компоненты" "$COMPONENTS" "api web release"
  st_eq "патчи 1.0.0" "$(patches_for 1.0.0)" ""
  st_eq "патчи 1.1.0" "$(patches_for 1.1.0)" "demo/1.1.0.patch"
  st_eq "патчи 1.2.0 накопительно" "$(patches_for 1.2.0)" "demo/1.1.0.patch demo/1.2.0.patch"
  st_refuses "патчи неизвестной версии" patches_for 1.3.0
  st_eq "тег образа" "$(image_tag 1.2.0 "$_c")" "demo-1.2.0-0123456789ab"
  st_eq "ссылка образа" "$(IMAGE_PREFIX=ghcr.io/o/r image_ref web 1.0.0 "$_c")" "ghcr.io/o/r/web:demo-1.0.0-0123456789ab"
  st_refuses "тег без полного sha" image_tag 1.0.0 0123abc
  st_refuses "префикс с заглавными" env IMAGE_PREFIX=ghcr.io/O/r sh "$0" --image-ref web 1.0.0 "$_c"

  # Патчи demo/ применяются к дереву коммита по порядку и без смещений; 1.2.0 ломает healthcheck web.
  if git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1 && command -v patch >/dev/null 2>&1; then
    mkdir -p "$_tmp/tree"
    git -C "$ROOT" archive HEAD | tar -x -C "$_tmp/tree"
    _applied=ok
    for _v in $VERSIONS; do
      [ -n "$(patches_for "$_v")" ] || continue
      _last=$(patches_for "$_v" | tr ' ' '\n' | tail -n 1)
      patch -d "$_tmp/tree" -p1 -N -s --fuzz=0 --no-backup-if-mismatch -i "$_tmp/tree/$_last" >/dev/null 2>&1 || _applied=no
      if [ "$_v" = 1.1.0 ]; then
        if grep -q -- '"--port", "8081"' "$_tmp/tree/release/compose.release.yaml"; then _applied=early; fi
      fi
    done
    st_eq "патчи 1.1.0 → 1.2.0 применяются к HEAD" "$_applied" ok
    if grep -q -- '"--port", "8081"' "$_tmp/tree/release/compose.release.yaml"; then
      st_ok "1.2.0: healthcheck web опрашивает 8081"
    else
      st_bad "1.2.0: в compose нет healthcheck на 8081"
    fi
    if grep -qxF '## 1.2.0' "$_tmp/tree/CHANGELOG.md"; then st_ok "1.2.0: раздел CHANGELOG"; else st_bad "1.2.0: нет раздела CHANGELOG"; fi
  else
    st_bad "нет git или patch — порядок патчей не проверен"
  fi

  # Строки lock: digest платформы из индекса, аттестации и лишние платформы — мимо.
  _row=$(st_index "$_d1" "$_d2" | PLATFORMS=linux/amd64,linux/arm64 LOCK_PLATFORMS=linux/amd64 lock_rows 1.0.0 api "$_c")
  st_eq "строка lock" "$_row" "1.0.0${TAB}api${TAB}linux/amd64${TAB}$_d1${TAB}$_c"
  _rows=$(st_index "$_d1" "$_d2" | PLATFORMS=linux/amd64,linux/arm64 LOCK_PLATFORMS=linux/amd64,linux/arm64 lock_rows 1.2.0 release "$_c" | wc -l)
  st_eq "строки lock на две платформы" "$_rows" 2
  # По умолчанию lock — все собранные платформы: робот arm64 (Jetson) берёт свою строку из того же пина.
  _def=$(st_index "$_d1" "$_d2" | env -u PLATFORMS -u LOCK_PLATFORMS sh "$0" --lock-rows 1.1.0 web "$_c" | cut -f3 | tr '\n' ' ')
  st_eq "строки lock по умолчанию — amd64 и arm64" "$_def" "linux/amd64 linux/arm64 "
  _one=$(st_index "$_d1" "$_d2" | env -u LOCK_PLATFORMS PLATFORMS=linux/amd64 sh "$0" --lock-rows 1.1.0 web "$_c" | cut -f3)
  st_eq "строки lock по умолчанию — платформы сборки" "$_one" "linux/amd64"
  if printf '%s\n' "$_row" | grep -Eq "^[0-9.]+${TAB}[a-z]+${TAB}linux/[a-z0-9]+${TAB}sha256:[0-9a-f]{64}${TAB}[0-9a-f]{40}\$"; then
    st_ok "формат строки lock"
  else
    st_bad "формат строки lock: «$_row»"
  fi
  st_refuses "индекс без arm64" sh -c "printf '%s' '$(st_index "$_d1" "")' | PLATFORMS=linux/amd64,linux/arm64 sh '$0' --lock-rows 1.0.0 api $_c"
  st_refuses "два манифеста amd64" sh -c "printf '%s' '$(st_index "$_d1" "$_d2" "$_d2")' | PLATFORMS=linux/amd64 sh '$0' --lock-rows 1.0.0 api $_c"
  st_refuses "digest не sha256" sh -c "printf '%s' '$(st_index "sha256:XYZ" "$_d2")' | PLATFORMS=linux/amd64 sh '$0' --lock-rows 1.0.0 api $_c"
  st_refuses "мусор вместо индекса" sh -c "printf 'not json' | PLATFORMS=linux/amd64 sh '$0' --lock-rows 1.0.0 api $_c"
  st_refuses "неизвестный компонент lock" sh -c "printf '%s' '$(st_index "$_d1" "$_d2")' | sh '$0' --lock-rows 1.0.0 db $_c"

  # Существующий тег не перезаписывается: build --push отказывает до первой сборки.
  st_fake_docker "$_tmp/bin"
  export ST_DOCKER_LOG="$_tmp/docker.log"
  st_eq "тег есть" "$(PATH="$_tmp/bin:$PATH" ST_DOCKER_MODE=exists tag_state ghcr.io/o/r/api:t)" exists
  st_eq "тега нет" "$(PATH="$_tmp/bin:$PATH" ST_DOCKER_MODE=absent tag_state ghcr.io/o/r/api:t)" absent
  st_refuses "отказ реестра — не «тега нет»" env PATH="$_tmp/bin:$PATH" ST_DOCKER_MODE=denied sh "$0" --tag-state ghcr.io/o/r/api:t
  : >"$ST_DOCKER_LOG"
  if env PATH="$_tmp/bin:$PATH" ST_DOCKER_MODE=exists sh "$0" build --push >"$_tmp/out" 2>&1; then
    st_bad "build --push при существующем теге не отказал"
  elif grep -q 'уже есть' "$_tmp/out" && ! grep -q '^buildx build' "$ST_DOCKER_LOG"; then
    st_ok "build --push: существующий тег — отказ до сборки"
  else
    st_bad "build --push: отказ без причины или после сборки: $(tr '\n' ' ' <"$_tmp/out")"
  fi

  # Публичный репозиторий: ни доменов портала, ни адресов, ни переменных портала в скрипте и workflow.
  _dom="stvor"'\.'
  _env="STVOR""_"
  _ip='(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.]|$)'
  for _f in scripts/demo-images.sh .github/workflows/demo-images.yml release/Dockerfile.bundle; do
    if [ ! -f "$ROOT/$_f" ]; then
      st_bad "нет $_f"
    elif grep -Eq -- "$_dom|$_env|$_ip" "$ROOT/$_f"; then
      st_bad "$_f: домен, адрес или переменная портала: $(grep -En -- "$_dom|$_env|$_ip" "$ROOT/$_f" | head -n 3 | tr '\n' ' ')"
    else
      st_ok "$_f: без доменов, адресов и переменных портала"
    fi
  done

  if [ "$ST_FAIL" = 0 ]; then echo "self-test: ok"; else
    echo "self-test: FAIL"
    exit 1
  fi
}

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  case ${1:-} in
    --self-test) self_test ;;
    --lock-rows)
      shift
      lock_rows "$@"
      ;;
    --tag-state)
      shift
      tag_state "$@"
      ;;
    --image-ref)
      shift
      image_ref "$@"
      ;;
    build)
      shift
      cmd_build "$@"
      ;;
    lock)
      shift
      cmd_lock "$@"
      ;;
    -h | --help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
