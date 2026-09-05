# CTF Infrastructure

Стек для проведения CTF-соревнований: **Nginx Proxy Manager** (реверс-прокси), **CTFd** (платформа) и контейнеры с тасками (challenges), каждая из которых живёт в своей папке со своим `Dockerfile`.

## Структура

```
.
├── docker-compose.yml          # весь стек: NPM + CTFd + MariaDB/Redis + таски
├── install.sh                  # клонирует репы и генерирует .env с рандомными кредами
├── .env.example                # шаблон конфига (создаётся через install.sh или вручную)
├── CTFd/                       # исходники CTFd (build context)
├── scripts/
│   ├── Dockerfile              # образ для авто-синка при `docker compose up`
│   ├── sync-tasks.sh           # генерирует секцию тасок в docker-compose.yml
│   ├── sync-npm-hosts.sh       # публикует CTFd и все таски в NPM через API
│   └── sync-ctfd.sh            # setup CTFd + создаёт челленджи через API
├── tasks/
│   └── <category>/             # категория (web, crypto, pwn, forensics, ...)
│       └── <task-name>/        # таска: Dockerfile + challenge.json + app.py
├── npm/                        # данные NPM (создаётся автоматически)
└── data/                       # данные CTFd/MySQL/Redis (создаётся автоматически)
```

## Быстрый старт

### Автоматически (рекомендуется)

`install.sh`:
1. ставит зависимости (git, curl, jq, python3);
2. клонирует CTFd;
3. спрашивает `BASE_DOMAIN` (по умолчанию `localhost`);
4. генерирует случайные креды NPM и CTFd в `.env` и печатает их в консоль;
5. генерирует секцию тасок в `docker-compose.yml`;
6. поднимает стек (`docker compose up -d --build`) — при этом `tasks-sync`, `npm-sync` и `ctfd-sync` сами выполнят sync-скрипты;
7. публикует таски в NPM через `sync-npm-hosts.sh`.

```bash
./install.sh
```

### Вручную

```bash
git clone https://github.com/CTFd/CTFd.git
cp .env.example .env    # вписать реальные пароли NPM
./scripts/sync-tasks.sh
docker compose up -d --build
```

После запуска:

| Сервис | Адрес |
|---|---|
| Панель NPM | http://localhost:81 |
| CTFd | http://ctf.`<BASE_DOMAIN>` |
| Таски | через NPM, по доменам `<name>.<BASE_DOMAIN>` |

При установке через `install.sh` креды NPM и CTFd выводятся в консоль; они же лежат в `.env`. При ручной установке по умолчанию `admin@example.com` / `changeme` (потом сменить в UI).

> **Первый запуск NPM:** админ с кредами из `.env` (`NPM_EMAIL`/`NPM_PASSWORD`) создаётся автоматически при первом старте — NPM получает их как `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD`. Никакой ручной настройки не нужно, `npm-sync` сам залогинится и опубликует хосты.

> **Первый запуск CTFd:** setup (название события, описание, режим, видимости, админ) берётся из `.env` (`CTF_*` и `CTF_ADMIN_*`) и выполняется автоматически сервисом `ctfd-sync`. Установочного мастера в браузере проходить не нужно.

CTFd не публикует порт наружу — наружу торчит только NPM (80/81/443). Прокси-хост для CTFd создаётся автоматически на домен `ctf.<BASE_DOMAIN>` → `ctfd:8000`.

### Автопубликация и заведение челленджей при `docker compose up`

Сервисы `tasks-sync`, `npm-sync` и `ctfd-sync` запускаются при каждом `docker compose up`:

- `tasks-sync` перегенерирует секцию тасок в `docker-compose.yml`;
- `npm-sync` публикует CTFd и все таски в NPM;
- `ctfd-sync` выполняет setup CTFd (если ещё не сделан) и создаёт/обновляет челленджи из `tasks/`.

Вручную то же самое делает:
```bash
./scripts/sync-tasks.sh
./scripts/sync-npm-hosts.sh
./scripts/sync-ctfd.sh
```

## Таски (challenges)

Каждая таска — папка `tasks/<category>/<task-name>/` с `Dockerfile` (сервис, слушающий HTTP на каком-то порту) и **обязательным** `challenge.json` с параметрами челленджа. Без `challenge.json` таска не публикуется: не попадает в `docker-compose.yml`, в NPM и в CTFd.

1. Создай папку `tasks/<category>/<name>/` с `Dockerfile`.
2. Добавь обязательный `challenge.json` — имя, описание, стоимость, категория, флаг:
```json
{
  "name": "My Task",
  "description": "Описание задачи",
  "category": "web",
  "value": 100,
  "flag": "flag{...}",
  "connection_info": "http://my-task.localhost",
  "tags": ["web"]
}
```
3. Сгенерируй секцию тасок в `docker-compose.yml`:
```bash
./scripts/sync-tasks.sh
```
4. Пересобери и запусти:
```bash
docker compose up -d --build
```

Скрипт `sync-tasks.sh` проходит по `tasks/<category>/*/` и добавляет в `docker-compose.yml` сервис только для папок, где есть и `Dockerfile`, и `challenge.json` (если чего-то не хватает — папка пропускается). Секция между маркерами `GENERATED_TASKS_START`/`GENERATED_TASKS_END` генерируется автоматически — вручную её править не нужно.

Имя сервиса — `task-<category>-<name>`, и так скрипты публикации понимают, куда форвардить. Флаг можно хранить в `challenge.json` (поле `flag`) или в файле `flag.txt` рядом с таской.

### Типовой цикл добавления таски

```bash
# 1. создал папку с таской, Dockerfile и challenge.json
mkdir -p tasks/web/my-task && vim tasks/web/my-task/Dockerfile
vim tasks/web/my-task/challenge.json

# 2. сгенерировал секцию в docker-compose.yml
./scripts/sync-tasks.sh

# 3. собрал и поднял (npm-sync опубликует в NPM, ctfd-sync заведёт челлендж)
docker compose up -d --build
```

После этого таска доступна по адресу `http://my-task.<BASE_DOMAIN>` (при `BASE_DOMAIN=localhost` — `http://my-task.localhost`), а в CTFd появится челлендж из `challenge.json`.

### Удаление таски

Удали папку `tasks/<category>/<name>/`, перезапусти `sync-tasks.sh` и `docker compose up -d`. Прокси-хост в NPM и челлендж в CTFd останутся — их можно удалить вручную в UI.

### Публикация через NPM

CTFd и все таски публикуются автоматически при `docker compose up` (сервис `npm-sync`) либо вручную скриптом `scripts/sync-npm-hosts.sh`, который логинится в API NPM и создаёт/обновляет прокси-хосты:

```bash
./scripts/sync-npm-hosts.sh
```

Публикуется:

- **CTFd** → `ctf.<BASE_DOMAIN>` → `ctfd:8000` (`CTFD_DOMAIN`, `CTFD_FORWARD_HOST`, `CTFD_FORWARD_PORT`)
- **таски** `tasks/<category>/<name>/` → `<name>.<BASE_DOMAIN>` → `task-<category>-<name>:8000` (`DEFAULT_FORWARD_PORT`, `DEFAULT_FORWARD_SCHEME`)

Скрипт идемпотентный: хост, уже существующий по домену, обновляется, а не дублируется.

### HTTPS и wildcard-сертификат

Если `EXTERNAL_SCHEME=https`, `install.sh` спрашивает DNS-провайдера, его credentials и **валидный email** для Let's Encrypt (этот email станет `NPM_EMAIL` — NPM использует его как email админа при регистрации в ACME). При поднятии стека `npm-sync` автоматически:

1. выпускает wildcard-сертификат `*.BASE_DOMAIN` через Let's Encrypt (DNS challenge — NPM сам ставит нужный плагин certbot);
2. привязывает его к каждому прокси-хосту (CTFd и все таски) и включает `ssl_forced` + http2.

Пример для DuckDNS:
```bash
EXTERNAL_SCHEME=https
DNS_PROVIDER=duckdns
DNS_PROVIDER_CREDENTIALS="dns_duckdns_token=your-token"
```

Многострочные credentials (regru, cloudflare, azure и др.) вводятся одной строкой через литерал `\n`:
```bash
DNS_PROVIDER=regru
DNS_PROVIDER_CREDENTIALS="dns_username=user\ndns_password=pass"
```

Требования для LE: домен должен резолвиться на этот сервер, провайдер DNS должен поддерживать DNS-challenge, а `NPM_EMAIL` должен быть реальным валидным email (не `@ctf.local` — ACME отклоняет такие домены). Полный список провайдеров и примеры credentials — в `.env.example`.

Если `DNS_PROVIDER`/`DNS_PROVIDER_CREDENTIALS` не заданы при https — хосты создадутся без SSL, сертификат можно добавить вручную в NPM (:81).

#### Переопределение через `tasks/<category>/<name>/npm.json`

Если таска слушает не тот порт, нужен свой домен или другой бэкенд:

```json
{
  "forward_port": 8080,
  "forward_scheme": "https",
  "forward_host": "task-web-example",
  "domains": ["special.ctf.local"]
}
```

### Доступ к таскам

Домены `<name>.<BASE_DOMAIN>` надо резолвить на хост, где крутится стек. Варианты:

- **`BASE_DOMAIN=localhost`** — для локального теста. Домен `*.localhost` резолвится в `127.0.0.1` автоматически (RFC 6761), `/etc/hosts` не нужен: таска `example` доступна по `http://example.localhost`.
- `/etc/hosts` (для локальных игр с другим доменом): `127.0.0.1 example.ctf.local`
- свой DNS с wildcard `*.ctf.local` (для реального ивента)

## Nginx Proxy Manager

Панель на `http://localhost:81`. Логин/пароль из `.env` (`NPM_EMAIL`/`NPM_PASSWORD`) — это админ, который создаётся автоматически при первом старте.

Прокси-хосты создаются автоматически скриптом через API (`/api/nginx/proxy-hosts`), вручную их добавлять не нужно.

## .env

| Переменная | Описание | По умолчанию |
|---|---|---|
| `NPM_URL` | Базовый URL API NPM | `http://localhost:81` |
| `NPM_EMAIL` | Логин админа NPM | генерируется `install.sh` |
| `NPM_PASSWORD` | Пароль админа NPM | генерируется `install.sh` |
| `BASE_DOMAIN` | Домен, на который вешаются таски и CTFd | `ctf.local` (для локального теста ставь `localhost`) |
| `DEFAULT_FORWARD_PORT` | Порт в контейнере таски по умолчанию | `8000` |
| `DEFAULT_FORWARD_SCHEME` | Схема форварда к контейнерам (всегда `http`) | `http` |
| `EXTERNAL_SCHEME` | Внешняя схема для пользователей (`http` / `https`) | `http` |
| `DNS_PROVIDER` | DNS-провайдер для wildcard-сертификата (при https) | пусто |
| `DNS_PROVIDER_CREDENTIALS` | Credentials-файл провайдера (при https) | пусто |
| `CTFD_DOMAIN` | Домен CTFd | `ctf.<BASE_DOMAIN>` |
| `CTFD_FORWARD_HOST` | Хост CTFd внутри сети | `ctfd` |
| `CTFD_FORWARD_PORT` | Порт CTFd внутри сети | `8000` |
| `CTFD_URL` | URL CTFd для API | `http://ctfd:8000` (из контейнера) |
| `CTF_ADMIN_NAME` | Имя админа CTFd (создаётся при setup) | `admin` |
| `CTF_ADMIN_EMAIL` | Email админа CTFd | генерируется `install.sh` |
| `CTF_ADMIN_PASSWORD` | Пароль админа CTFd | генерируется `install.sh` |
| `CTF_NAME` | Название события | `My CTF` |
| `CTF_DESCRIPTION` | Описание события | пусто |
| `CTF_MODE` | Режим: `users` или `teams` | `users` |
| `CTF_CHALLENGE_VISIBILITY` | `public` / `private` / `admins` | `private` |
| `CTF_ACCOUNT_VISIBILITY` | `public` / `private` / `admins` | `public` |
| `CTF_SCORE_VISIBILITY` | `public` / `private` / `hidden` / `admins` | `public` |
| `CTF_REGISTRATION_VISIBILITY` | `public` / `private` / `mlc` | `public` |
| `CTF_START` / `CTF_END` | Время старта/конца события | пусто |
| `CTF_THEME` | Тема CTFd | `core-beta` |