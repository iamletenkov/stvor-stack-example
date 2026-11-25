#!/bin/sh
# stvor-stack-publish.sh — публикация релиза стека в Stvor из CI или вручную.
#
# Отдаётся порталом только сессией (`GET /api/stacks/publish-script`, ADR-0047: анонимного пути нет); один скрипт на
# любой стек. Образы к запуску уже отправлены в реестр (`docker buildx build … --push` в `registry.<домен>/stacks/<слаг>/`).
#
#   STVOR_STACK_KEY=sck_… stvor-stack-publish.sh --url https://<домен> --stack <слаг> --version <semver> \
#       [--variant <вариант>] [--dir <каталог релиза>]
#   stvor-stack-publish.sh --self-test
#
# Ключ стека (CI или личный) — только из переменной окружения STVOR_STACK_KEY: аргумент с `sck_` — отказ, ключ не
# печатается и не попадает в argv процессов — curl получает его конфигом со stdin (`--config -`). Трассировки shell нет.
#
# Каталог релиза (по умолчанию — текущий): `compose.yaml`, `CHANGELOG.md`, при наличии `parameters.yaml` и
# `changes.json`, и `release.json` — готовый или собранный из `release.template.json` подстановкой `__STACK__`,
# `__VARIANT__`, `__VERSION__`, `__CREATED_AT__`, `__COMPOSE_DIGEST__`, `__PARAMETERS_DIGEST__` (остальное, например
# `release_counter` и `components`, команда заполняет сама). Готовый `release.json` не переписывается — повтор
# отправляет те же байты. Скрипт:
#   1. сверяет `stack`, `variant`, `version` и суммы `compose.yaml`/`parameters.yaml` в `release.json`;
#   2. пишет `SHA256SUMS` всех отправляемых файлов;
#   3. проверяет каждый образ `stacks/<слаг>/…@sha256:…` из `release.json` в реестре по digest (`HEAD` манифеста под
#      логином `ci`; docker не нужен — вся сеть через curl);
#   4. регистрирует релиз: `POST <адрес>/api/stack-ci/v1/releases` (multipart, часть на файл).
#
# Коды выхода: 0 — релиз зарегистрирован (201) или уже был с теми же байтами (200); 2 — ошибка ввода; 3 — релиз не
# принят (422 с причинами, 409, 413, образа нет в реестре); 4 — ключ не принят (401/403); 5 — сеть, 5xx, 503.
# Свой CA — переменной CURL_CA_BUNDLE. Требуются: curl, sha256sum, grep, sed, sort, date (подходят busybox и coreutils).
set -eu
umask 077

PROG=stvor-stack-publish.sh
NL='
'
SLUG_RE='^[a-z0-9][a-z0-9-]{1,39}$'
VARIANT_RE='^[a-z0-9][a-z0-9._-]{0,39}$'
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
URL_RE='^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?/?$'
KEY_RE='^sck_[A-Za-z0-9_-]{16,128}={0,2}$'
ACCEPT='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
BODY_MAX=65536

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() {
  _code=$1
  shift
  say "$*"
  exit "$_code"
}

usage() {
  cat <<'EOF'
Использование:
  STVOR_STACK_KEY=sck_… stvor-stack-publish.sh --url https://<домен> --stack <слаг> --version <semver> \
      [--variant <вариант>] [--dir <каталог релиза>]
  stvor-stack-publish.sh --self-test

Ключ стека — только переменной окружения STVOR_STACK_KEY (masked-переменная CI), не аргументом.
Коды выхода: 0 — зарегистрирован; 2 — ввод; 3 — релиз не принят; 4 — ключ не принят; 5 — сеть или реестр.
EOF
}

# Значение целиком соответствует ERE (одна строка; перевод строки — несоответствие).
matches() {
  case $1 in *"$NL"*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq -- "$2"
}

# Экранирование значения (слаг, вариант, версия — после проверки масок) для ERE.
ere() { printf '%s' "$1" | sed 's/[.+]/\\&/g'; }

sha256_of() {
  _sum=$(sha256sum -- "$1") || die 2 "не прочитан $1"
  printf '%s' "${_sum%% *}"
}

show_body() {
  [ -s "$1" ] || return 0
  if command -v jq >/dev/null 2>&1 && jq -e '.reasons | type == "array"' "$1" >/dev/null 2>&1; then
    jq -r '"\(.code // ""): \(.message // "")", (.reasons[] | "  \(.code) \(.field): \(.detail)")' "$1" >&2
  else
    head -c "$BODY_MAX" "$1" >&2
    printf '\n' >&2
  fi
}

# Запрос с учёткой `ci:<ключ>`: ключ — только в конфиге curl со stdin (printf — встроенная команда, в argv его нет).
# $1 — файл тела ответа, дальше — аргументы curl; печатает HTTP-код, код выхода — код curl.
http() {
  _out=$1
  shift
  printf 'user = "ci:%s"\n' "$KEY" | curl --config - --silent --show-error --proto =https \
    --connect-timeout 20 -o "$_out" -w '%{http_code}' "$@"
}

render_template() {
  [ -f release.template.json ] || die 2 "в каталоге релиза нет release.json и release.template.json"
  _compose=sha256:$(sha256_of compose.yaml)
  _params=
  if [ -f parameters.yaml ]; then _params=sha256:$(sha256_of parameters.yaml); fi
  _created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _rendered=$WORK/release.json
  set -- -e "s|__STACK__|$STACK|g" -e "s|__VERSION__|$VERSION|g" -e "s|__CREATED_AT__|$_created|g" \
    -e "s|__COMPOSE_DIGEST__|$_compose|g"
  if [ -n "$VARIANT" ]; then set -- "$@" -e "s|__VARIANT__|$VARIANT|g"; fi
  if [ -n "$_params" ]; then set -- "$@" -e "s|__PARAMETERS_DIGEST__|$_params|g"; fi
  sed "$@" release.template.json >"$_rendered"
  _left=$(grep -Eo '__[A-Z0-9_]+__' "$_rendered" | sort -u | tr '\n' ' ') || true
  if [ -n "$_left" ]; then
    die 2 "release.template.json: не заполнены ${_left}(__VARIANT__ — по --variant, __PARAMETERS_DIGEST__ — при parameters.yaml)"
  fi
  cat "$_rendered" >release.json
  say "release.json собран из release.template.json"
}

check_release_json() {
  grep -Eq "\"stack\"[[:space:]]*:[[:space:]]*\"$(ere "$STACK")\"" release.json \
    || die 2 "release.json: stack не равен «$STACK»"
  grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"$(ere "$VERSION")\"" release.json \
    || die 2 "release.json: version не равна «$VERSION»"
  if [ -n "$VARIANT" ]; then
    grep -Eq "\"variant\"[[:space:]]*:[[:space:]]*\"$(ere "$VARIANT")\"" release.json \
      || die 2 "release.json: variant не равен «$VARIANT»"
  fi
  grep -Fq "sha256:$(sha256_of compose.yaml)" release.json \
    || die 2 "release.json: compose.digest не равен sha256 файла compose.yaml"
  if [ -f parameters.yaml ]; then
    grep -Fq "sha256:$(sha256_of parameters.yaml)" release.json \
      || die 2 "release.json: parameters.digest не равен sha256 файла parameters.yaml"
  fi
  IMAGES=$(grep -Eo "stacks/$STACK/[a-z0-9]+([._-]+[a-z0-9]+)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[0-9a-f]{64}" \
    release.json | sort -u) || true
  [ -n "$IMAGES" ] || die 2 "release.json: нет образов stacks/$STACK/<сервис>[:<тег>]@sha256:<digest>"
}

write_sums() {
  set -- release.json compose.yaml
  if [ -f parameters.yaml ]; then set -- "$@" parameters.yaml; fi
  set -- "$@" CHANGELOG.md
  if [ -f changes.json ]; then set -- "$@" changes.json; fi
  sha256sum -- "$@" >SHA256SUMS || die 2 "SHA256SUMS не записан"
  FILES=$*
}

check_images() {
  for _ref in $IMAGES; do
    _repo=${_ref%@*}
    _repo=${_repo%%:*}
    _digest=${_ref##*@}
    if ! _status=$(http "$WORK/head" --head --max-time 60 -H "Accept: $ACCEPT" \
      "$REGISTRY/v2/$_repo/manifests/$_digest"); then
      die 5 "реестр $REGISTRY недоступен — повторите тем же каталогом"
    fi
    case $_status in
      200) say "образ есть в реестре: $_ref" ;;
      401 | 403) die 4 "реестр не принял ключ для $_repo ($_status): проверьте STVOR_STACK_KEY и стек" ;;
      404) die 3 "образа нет в реестре: $_ref — сначала отправьте его (docker buildx build … --push)" ;;
      *) die 5 "реестр ответил $_status на $_ref — повторите позже" ;;
    esac
  done
}

register() {
  set --
  for _file in $FILES SHA256SUMS; do set -- "$@" -F "$_file=@$_file"; done
  if ! _status=$(http "$WORK/post" --max-time 600 "$@" "$BASE/api/stack-ci/v1/releases"); then
    die 5 "портал $BASE недоступен — повторите тем же каталогом (те же байты дадут 200)"
  fi
  case $_status in
    201 | 200)
      head -c "$BODY_MAX" "$WORK/post"
      printf '\n'
      if [ "$_status" = 201 ]; then say "релиз зарегистрирован"; else say "релиз с теми же байтами уже зарегистрирован"; fi
      exit 0
      ;;
    401 | 403)
      show_body "$WORK/post"
      die 4 "портал не принял ключ ($_status): ключ не отозван, стек и срок личного ключа, право «Стеки»"
      ;;
    404) die 2 "по адресу $BASE нет регистрации релизов — проверьте --url" ;;
    422 | 409 | 413 | 400)
      show_body "$WORK/post"
      die 3 "релиз не принят ($_status) — исправьте причины, не повторяйте вслепую"
      ;;
    *)
      show_body "$WORK/post"
      die 5 "портал ответил $_status — повторите тем же каталогом позже"
      ;;
  esac
}

publish() {
  STACK=
  VERSION=
  VARIANT=
  URL=
  DIR=.
  while [ "$#" -gt 0 ]; do
    case $1 in
      --url | --stack | --version | --variant | --dir)
        [ "$#" -ge 2 ] || die 2 "у $1 нет значения"
        case $1 in
          --url) URL=$2 ;;
          --stack) STACK=$2 ;;
          --version) VERSION=$2 ;;
          --variant) VARIANT=$2 ;;
          --dir) DIR=$2 ;;
        esac
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die 2 "неизвестный параметр $1 (--help)" ;;
      *) die 2 "лишнее значение без параметра (--help)" ;;
    esac
  done
  if [ -z "$URL" ] || [ -z "$STACK" ] || [ -z "$VERSION" ]; then die 2 "нужны --url, --stack и --version (--help)"; fi
  matches "$URL" "$URL_RE" || die 2 "--url: ожидается https://<домен>[:<порт>] без пути, имя — строчными буквами"
  matches "$STACK" "$SLUG_RE" || die 2 "--stack: слаг — a-z, 0-9 и «-», 2…40 знаков"
  if [ "${#VERSION}" -gt 64 ] || ! matches "$VERSION" "$SEMVER_RE"; then die 2 "--version: SemVer без «v», например 1.0.0"; fi
  if [ -n "$VARIANT" ]; then
    matches "$VARIANT" "$VARIANT_RE" || die 2 "--variant: a-z, 0-9, «.», «_», «-», до 40 знаков"
  fi
  KEY=${STVOR_STACK_KEY-}
  [ -n "$KEY" ] || die 2 "задайте ключ стека переменной окружения STVOR_STACK_KEY"
  matches "$KEY" "$KEY_RE" || die 2 "STVOR_STACK_KEY: это не ключ стека (ожидается sck_…)"
  for _tool in curl sha256sum grep sed sort date; do
    command -v "$_tool" >/dev/null 2>&1 || die 2 "нужна программа $_tool"
  done
  HOSTPORT=${URL#https://}
  HOSTPORT=${HOSTPORT%/}
  BASE=https://$HOSTPORT
  REGISTRY=https://registry.$HOSTPORT

  [ -d "$DIR" ] || die 2 "--dir: нет каталога $DIR"
  cd -- "$DIR"
  for _need in compose.yaml CHANGELOG.md; do
    [ -f "$_need" ] || die 2 "в каталоге релиза нет $_need"
  done
  WORK=$(mktemp -d)
  trap 'rm -f "$WORK"/*; rmdir "$WORK"' EXIT
  if [ ! -f release.json ]; then render_template; fi
  check_release_json
  write_sums
  check_images
  register
}

# ---------- Самопроверка: подменные curl и docker в PATH, сценарии по кодам выхода ----------

ST_RUNS=0
ST_FAILS=0

st_check() {
  ST_RUNS=$((ST_RUNS + 1))
  if [ "$2" = "$3" ]; then return 0; fi
  ST_FAILS=$((ST_FAILS + 1))
  printf 'FAIL %s: ожидали %s, получили %s\n' "$1" "$2" "$3"
}

# $1 — имя сценария, $2 — ожидаемый код; дальше — `env`-присваивания и аргументы скрипта. Вывод — в $ST/out.
st_run() {
  _name=$1
  _want=$2
  shift 2
  : >"$ST/calls.log"
  _got=0
  env PATH="$ST/bin:$PATH" STVOR_STACK_KEY="$ST_KEY" FAKE_DIR="$ST" "$@" >"$ST/out" 2>&1 || _got=$?
  cat "$ST/out" >>"$ST/all.out"
  st_check "$_name" "$_want" "$_got"
}

st_has() {
  if grep -Fq -- "$2" "$3"; then st_check "$1" yes yes; else st_check "$1" yes no; fi
}

st_lacks() {
  if grep -Fq -- "$2" "$3"; then st_check "$1" no yes; else st_check "$1" no no; fi
}

st_fixture() {
  mkdir -p "$ST/bin" "$ST/rel"
  cat >"$ST/bin/curl" <<'EOF'
#!/bin/sh
# Подменный curl самопроверки: пишет argv, stdin (--config -) и вызовы; отвечает по FAKE_*.
printf '%s\n' "$*" >>"$FAKE_DIR/argv.log"
out=/dev/null
method=GET
url=
parts=
cfg=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --config) [ "$2" = - ] && cfg=1; shift 2 ;;
    --head) method=HEAD; shift ;;
    -o) out=$2; shift 2 ;;
    -w | -H | --proto | --connect-timeout | --max-time) shift 2 ;;
    -F) method=POST; parts="$parts ${2%%=*}"; shift 2 ;;
    https://* | http://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ "$cfg" = 1 ]; then cat >>"$FAKE_DIR/stdin.log"; fi
if [ "${FAKE_NET:-0}" = 1 ]; then echo "curl: (7) Failed to connect" >&2; exit 7; fi
printf '%s %s%s\n' "$method" "$url" "$parts" >>"$FAKE_DIR/calls.log"
if [ "$method" = HEAD ]; then
  : >"$out"
  printf '%s' "${FAKE_HEAD_CODE:-200}"
else
  body=${FAKE_POST_BODY-}
  [ -n "$body" ] || body='{"id":"0193a4f2-6c1e-7b3d-9a5e-2f8c4d1b7e60","status":"available"}'
  printf '%s' "$body" >"$out"
  printf '%s' "${FAKE_POST_CODE:-201}"
fi
EOF
  cat >"$ST/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$FAKE_DIR/docker.log"
exit 99
EOF
  chmod +x "$ST/bin/curl" "$ST/bin/docker"
  _a=aaaaaaaaaaaaaaaa
  ST_DIGEST=sha256:$_a$_a$_a$_a
  printf 'services:\n  app:\n    image: registry.stvor.test/stacks/demo/app:1.0.0@%s\n' "$ST_DIGEST" >"$ST/rel/compose.yaml"
  printf 'parameters: []\n' >"$ST/rel/parameters.yaml"
  printf '# 1.0.0\n\nПервый релиз.\n' >"$ST/rel/CHANGELOG.md"
  cat >"$ST/rel/release.template.json" <<EOF
{
  "schema": 2,
  "stack": "__STACK__",
  "variant": "__VARIANT__",
  "version": "__VERSION__",
  "release_counter": 1,
  "created_at": "__CREATED_AT__",
  "images": ["stacks/demo/app:1.0.0@$ST_DIGEST"],
  "compose": {"file": "compose.yaml", "digest": "__COMPOSE_DIGEST__"},
  "parameters": {"file": "parameters.yaml", "digest": "__PARAMETERS_DIGEST__"}
}
EOF
}

self_test() {
  SELF=$0
  [ -f "$SELF" ] || die 2 "--self-test запускается из файла: sh stvor-stack-publish.sh --self-test"
  ST=$(mktemp -d)
  trap 'rm -rf "$ST"' EXIT
  # Не настоящий ключ: собирается при запуске, в файле скрипта его нет.
  ST_KEY=sck_$(printf 'selftest%.0s' 1 2 3)
  st_fixture
  set -- sh "$SELF" --url https://stvor.test --stack demo --version 1.0.0 --variant amd64 --dir "$ST/rel"

  st_run "201 — зарегистрирован" 0 "$@"
  st_lacks "release.json без заглушек" "__" "$ST/rel/release.json"
  st_has "release.json: сумма compose.yaml" "sha256:$(sha256_of "$ST/rel/compose.yaml")" "$ST/rel/release.json"
  _verify=0
  (cd "$ST/rel" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || _verify=$?
  st_check "SHA256SUMS сходится" 0 "$_verify"
  st_has "образ проверен HEAD по digest" "HEAD https://registry.stvor.test/v2/stacks/demo/app/manifests/$ST_DIGEST" \
    "$ST/calls.log"
  st_has "регистрация с частями файлов" \
    "POST https://stvor.test/api/stack-ci/v1/releases release.json compose.yaml parameters.yaml CHANGELOG.md SHA256SUMS" \
    "$ST/calls.log"
  _before=$(sha256_of "$ST/rel/release.json")

  st_run "повтор 200 — успех" 0 FAKE_POST_CODE=200 "$@"
  st_check "повтор не переписал release.json" "$_before" "$(sha256_of "$ST/rel/release.json")"
  st_run "422 — код 3" 3 FAKE_POST_CODE=422 \
    FAKE_POST_BODY='{"code":"stacks.release_rejected","message":"Релиз не принят","reasons":[{"code":"sum_mismatch","field":"SHA256SUMS","detail":"сумма не сходится"}]}' \
    "$@"
  st_has "422 — причины напечатаны" "sum_mismatch" "$ST/out"
  st_run "409 — код 3" 3 FAKE_POST_CODE=409 "$@"
  st_run "401 — код 4" 4 FAKE_POST_CODE=401 "$@"
  st_run "503 — код 5" 5 FAKE_POST_CODE=503 "$@"
  st_run "сеть — код 5" 5 FAKE_NET=1 "$@"
  st_run "образа нет — код 3" 3 FAKE_HEAD_CODE=404 "$@"
  st_lacks "без образа регистрации нет" "POST " "$ST/calls.log"
  st_run "реестр 401 — код 4" 4 FAKE_HEAD_CODE=401 "$@"
  st_run "чужой стек в release.json — код 2" 2 sh "$SELF" --url https://stvor.test --stack other --version 1.0.0 \
    --dir "$ST/rel"
  st_run "ключ аргументом — код 2" 2 sh "$SELF" --url https://stvor.test --stack demo --version "$ST_KEY"
  st_lacks "ключ из аргумента не напечатан" "$ST_KEY" "$ST/out"
  st_run "без ключа — код 2" 2 STVOR_STACK_KEY= "$@"
  st_run "http:// — код 2" 2 sh "$SELF" --url http://stvor.test --stack demo --version 1.0.0 --dir "$ST/rel"
  st_run "кривой слаг — код 2" 2 sh "$SELF" --url https://stvor.test --stack Demo_1 --version 1.0.0 --dir "$ST/rel"
  st_run "кривая версия — код 2" 2 sh "$SELF" --url https://stvor.test --stack demo --version v1.0 --dir "$ST/rel"

  st_has "ключ ушёл конфигом curl со stdin" "user = \"ci:$ST_KEY\"" "$ST/stdin.log"
  st_lacks "ключа нет в argv curl" "$ST_KEY" "$ST/argv.log"
  st_lacks "ключа нет в выводе" "$ST_KEY" "$ST/all.out"
  if [ -e "$ST/docker.log" ]; then st_check "docker не вызывался" no yes; else st_check "docker не вызывался" no no; fi

  if [ "$ST_FAILS" -gt 0 ]; then
    printf 'self-test: FAIL (%s из %s)\n' "$ST_FAILS" "$ST_RUNS"
    exit 1
  fi
  printf 'self-test: ok (%s проверок)\n' "$ST_RUNS"
}

main() {
  for _arg in "$@"; do
    case $_arg in
      *sck_*) die 2 "ключ стека в аргументах не принимается — передайте его переменной окружения STVOR_STACK_KEY" ;;
    esac
  done
  if [ "$#" -eq 1 ] && [ "$1" = --self-test ]; then
    self_test
    exit 0
  fi
  publish "$@"
}

main "$@"
