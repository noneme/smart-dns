#!/usr/bin/env bash
#
# ============================================================================
# Smart DNS: полная настройка VPS
#   - Let's Encrypt сертификат (certbot --standalone, порт 80 свободен)
#   - монтирование сертификатов в adguard/docker-compose.yml
#   - установка apache2-utils + merecat
#   - генерация bcrypt-хеша (htpasswd -B) и запись в секцию users
#   - включение TLS в AdGuardHome_start.yaml (server_name, fullchain/privkey)
#   - генерация map-записей Nginx и rewrites AdGuard из domains.txt
#   - установка nginx.conf в /etc/nginx (с резервной копией), nginx -t, reload
#   - установка AdGuardHome.yaml в adguard/conf и docker compose up -d
#
# Использование:
#   ./setup_smart_dns.sh domains.txt <answer_ip> [domain] [email] [login] [password]
#
# Если остальные параметры не переданы — скрипт запросит их интерактивно.
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------- аргументы
DOMAINS_FILE="${1:-}"
ANSWER_IP="${2:-}"
DOMAIN="${3:-}"
CERT_EMAIL="${4:-}"
LOGIN="${5:-}"
PASSWORD="${6:-}"

if [[ -z "$DOMAINS_FILE" || -z "$ANSWER_IP" ]]; then
    echo "Usage: $0 domains.txt <answer_ip> [domain] [email] [login] [password]" >&2
    exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: запускайте от root (sudo)." >&2
    exit 1
fi

# ------------------------------------------------------------------- пути
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ADGUARD_DIR="$BASE_DIR/adguard"
COMPOSE_FILE="$ADGUARD_DIR/docker-compose.yml"
YAML_SRC="$BASE_DIR/AdGuardHome_start.yaml"
YAML_DST="$ADGUARD_DIR/conf/AdGuardHome.yaml"
NGINX_SRC="$BASE_DIR/nginx/nginx.conf"
NGINX_ETC="/etc/nginx/nginx.conf"
LETSENCRYPT_LIVE="/etc/letsencrypt/live"

log()  { echo -e "\033[1;32m[OK]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[..]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[!!]\033[0m  $*" >&2; exit 1; }

# ------------------------------------------- интерактивный ввод (если нужно)
if [[ -z "$DOMAIN" ]]; then
    read -r -p "Домен для сертификата / server_name (напр. dns.example.com): " DOMAIN
fi
[[ -z "$DOMAIN" ]] && die "Домен не указан."
if [[ -z "$CERT_EMAIL" ]]; then
    read -r -p "Email для Let's Encrypt (пусто = без email): " CERT_EMAIL
fi
if [[ -z "$LOGIN" ]]; then
    read -r -p "Логин админки AdGuard Home: " LOGIN
fi
if [[ -z "$PASSWORD" ]]; then
    read -r -s -p "Пароль админки AdGuard Home: " PASSWORD; echo
fi
[[ -z "$LOGIN" ]]    && die "Логин не указан."
[[ -z "$PASSWORD" ]] && die "Пароль не указан."

CERT_DIR="$LETSENCRYPT_LIVE/$DOMAIN"
export DEBIAN_FRONTEND=noninteractive

log "База: $BASE_DIR | домен: $DOMAIN | answer_ip: $ANSWER_IP"

# ============================================================================
# 3. Установка библиотек apache2-utils и merecat (+ python3-yaml для правки YAML)
# ============================================================================
log "Установка пакетов: apache2-utils, merecat, python3-yaml"
apt-get update -y

MERE_INSTALLED=no
dpkg -l merecat 2>/dev/null | grep -Eq '^ii\s+merecat' && MERE_INSTALLED=yes

if [[ "$MERE_INSTALLED" == "yes" ]]; then
    # Повторный запуск: оба пакета уже стоят. apt больше нельзя дёргать —
    # merecat декларирует Conflicts: apache2-utils, и apt откажется работать.
    warn "merecat уже установлен — установку apt пропускаю (конфликт Conflicts: apache2-utils)"
else
    # Чистая установка: сначала apache2-utils и зависимости (пока без конфликта),
    # затем merecat напрямую через dpkg (файлы не пересекаются: /usr/bin vs /usr/sbin).
    # ВАЖНО: никогда не запускать 'apt-get install -y -f' после — apt удалит merecat.
    log "Установка apache2-utils, python3-yaml и зависимостей"
    apt-get install -y apache2-utils python3-yaml libconfuse2 libcrypt1 libssl3t64 zlib1g ucf
    dpkg -P merecat 2>/dev/null || true   # чистка stale-записи от прерванной предыдущей установки
    log "Установка merecat (dpkg --force-conflicts --force-overwrite)"
    ( cd /tmp && apt-get download merecat && dpkg --force-conflicts --force-overwrite -i merecat_*.deb ) \
        || { rm -f /tmp/merecat_*.deb; die "не удалось установить merecat"; }
    rm -f /tmp/merecat_*.deb
fi

# systemd-сервис merecat по умолчанию слушает :80 — отключаем, чтобы не мешать certbot standalone
if systemctl list-unit-files 2>/dev/null | grep -q '^merecat.service'; then
    systemctl stop merecat.service 2>/dev/null || true
    systemctl disable merecat.service 2>/dev/null || true
fi

command -v certbot  >/dev/null || die "certbot не установлен"
[[ -x /usr/bin/htpasswd ]] || die "htpasswd (apache2-utils) не установлен"
{ command -v merecat >/dev/null 2>&1 || [[ -x /usr/sbin/merecat ]]; } \
    || die "merecat не установлен"
log "Пакеты установлены (apache2-utils + merecat)."

# ============================================================================
# 1. Let's Encrypt сертификат
# ============================================================================
if [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]]; then
    warn "Сертификат уже есть: $CERT_DIR — пропуск."
else
    log "Выпуск Let's Encrypt сертификата для $DOMAIN (standalone, порт 80)"
    ARGS=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring -d "$DOMAIN")
    if [[ -z "$CERT_EMAIL" || "$CERT_EMAIL" == "-" ]]; then
        ARGS+=(--register-unsafely-without-email)
    else
        ARGS+=(--email "$CERT_EMAIL")
    fi
    certbot "${ARGS[@]}"
    [[ -f "$CERT_DIR/fullchain.pem" && -f "$CERT_DIR/privkey.pem" ]] \
        || die "Сертификат не выпущен. Проверьте, что $DOMAIN резолвится на $ANSWER_IP и порт 80 открыт."
fi
log "Сертификат: $CERT_DIR"
ls -l "$CERT_DIR"/fullchain.pem "$CERT_DIR"/privkey.pem

# renew-hook: после обновления сертификата перезапускаем AdGuard Home,
# чтобы контейнер подхватил новые fullchain.pem/privkey.pem
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/restart-adguardhome.sh" <<'HOOKEOF'
#!/bin/sh
# certbot deploy-hook: перезапуск AdGuard Home после обновления сертификата
docker restart adguardhome >/dev/null 2>&1 || true
HOOKEOF
chmod +x "$HOOK_DIR/restart-adguardhome.sh"
log "Deploy-hook: $HOOK_DIR/restart-adguardhome.sh"

# ============================================================================
# 2. docker-compose.yml: путь к сертификатам
#    Монтируем именно ФАЙЛЫ live/<domain>/fullchain.pem и privkey.pem:
#    каталог live/ нельзя монтировать целиком — файлы в нём это относительные
#    симлинки на ../../archive, которые в контейнере (/opt/certs) битые.
#    Docker при bind-монтировании файла-симлинка подставляет реальный файл.
# ============================================================================
log "Правка $COMPOSE_FILE (пер-файловые маунты сертификатов)"
export CERT_DIR COMPOSE_FILE
python3 - <<'PYEOF'
import os, re
path = os.environ["COMPOSE_FILE"]
cert_dir = os.environ["CERT_DIR"]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# удаляем любые старые строки маунта, содержащие /opt/certs (и ../nginx/certs, и пер-файловые)
cleaned = []
removed = 0
for line in text.splitlines():
    if "/opt/certs" in line:
        removed += 1
        continue
    cleaned.append(line)
text = "\n".join(cleaned)

# вставляем два пер-файловых маунта после строки ./conf
anchor = "      - ./conf:/opt/adguardhome/conf"
assert anchor in text, "anchor './conf:/opt/adguardhome/conf' не найден в compose"
mounts = (
    f"      - {cert_dir}/fullchain.pem:/opt/certs/fullchain.pem:ro\n"
    f"      - {cert_dir}/privkey.pem:/opt/certs/privkey.pem:ro"
)
text = text.replace(anchor, anchor + "\n" + mounts)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print(f"compose: удалено старых маунтов: {removed}, добавлено: fullchain.pem + privkey.pem")
PYEOF
grep -n "/opt/certs" "$COMPOSE_FILE"

# ============================================================================
# 4. Генерация логина/пароля : htpasswd -B -n -b {login} {password}
#    Явно вызываем /usr/bin/htpasswd (apache2-utils, поддерживает -B bcrypt):
#    у merecat свой /usr/sbin/htpasswd, который встаёт раньше в PATH root
#    и флаг -B не понимает.
# ============================================================================
log "Генерация bcrypt-хеша для пользователя '$LOGIN'"
HASH="$(/usr/bin/htpasswd -B -n -b "$LOGIN" "$PASSWORD" | cut -d: -f2- | tr -d '\r\n')"
[[ -n "$HASH" ]] || die "Ошибка htpasswd"
log "Хеш получен (${#HASH} символов)."

# ============================================================================
# 7a. Генерация map-записей Nginx и rewrites AdGuard (из domains.txt)
# ============================================================================
GEN_OUT="$(mktemp)"
gen_entries() {
    local DOMAINS_FILE="$1" ANSWER_IP="$2"
    declare -a DOMAINS_ORDER
    declare -A SEEN
    declare -A WILDCARDS

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        DOMAINS_ORDER+=("$domain")
        if [[ "$domain" =~ ^\*\.(.+)$ ]]; then
            WILDCARDS["${BASH_REMATCH[1]}"]=1
        fi
    done < "$DOMAINS_FILE"

    # --- NGINX map ---
    echo "### --- NGINX map entries ---"
    for domain in "${DOMAINS_ORDER[@]}"; do
        [[ -z "$domain" ]] && continue
        if [[ ! "$domain" =~ ^\*\.(.+)$ ]]; then
            [[ -n "${SEEN[$domain]+x}" ]] && continue
            SEEN["$domain"]=1
            echo "    \"~^${domain}\$\"             \$ssl_preread_server_name:443;"
            if [[ -n "${WILDCARDS[$domain]+x}" ]]; then
                echo "    \"~^.*\\.${domain}\$\"         \$ssl_preread_server_name:443;"
            fi
        else
            base="${BASH_REMATCH[1]}"
            [[ -n "${SEEN[$base]+x}" ]] && continue
            SEEN["$base"]=1
            echo "    \"~^${base}\$\"             \$ssl_preread_server_name:443;"
            echo "    \"~^.*\\.${base}\$\"         \$ssl_preread_server_name:443;"
        fi
    done

    # --- Adguard rewrites ---
    echo
    echo "### --- Adguard rewrites ---"
    echo "  rewrites:"
    for domain in "${DOMAINS_ORDER[@]}"; do
        [[ -z "$domain" ]] && continue
        echo "    - domain: \"$domain\""
        echo "      answer: $ANSWER_IP"
        echo "      enabled: true"
    done
}
gen_entries "$DOMAINS_FILE" "$ANSWER_IP" > "$GEN_OUT"

# map-строки (только между маркерами)
MAP_TMP="$(mktemp)"
awk 'BEGIN{f=0} /^### --- NGINX map entries ---/{f=1; next} /^### --- Adguard rewrites ---/{f=0} f' "$GEN_OUT" \
    | sed '/^[[:space:]]*$/d' > "$MAP_TMP"
[[ -s "$MAP_TMP" ]] || die "Не удалось извлечь map-записи"
log "Сгенерировано map-записей: $(wc -l < "$MAP_TMP"), rewrites: $(($(grep -c '^\s*- domain:' "$GEN_OUT")))"

# ============================================================================
# 5, 6, 7b. Правка AdGuardHome_start.yaml (users, tls, filtering.rewrites)
#            и вставка map-записей в nginx/nginx.conf
# ============================================================================
# Перед вставкой восстанавливаем эталонный шаблон проекта nginx/nginx.conf
# (маркер может быть уже заменён прошлым запуском — это делает скрипт идемпотентным)
log "Восстановление шаблона $NGINX_SRC"
cat > "$NGINX_SRC" <<'NGINX_TEMPLATE'
#user  nginx;
user www-data;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;
load_module /usr/lib/nginx/modules/ngx_stream_module.so;

events {
    worker_connections 1024;
}

stream {
    map $ssl_preread_server_name $backend {
        dns.example.com   127.0.0.1:9443;

        ### --- NGINX map entries ---
        
        default                      127.255.255.255:443;
    }

    server {
        listen 443;

        resolver 1.1.1.1 1.0.0.1 ipv6=on valid=300s;
        ssl_preread on;

        proxy_connect_timeout 15s;
        proxy_timeout 90s;

        proxy_pass $backend;
    }
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}
NGINX_TEMPLATE

export LOGIN HASH DOMAIN GEN_OUT MAP_TMP YAML_SRC NGINX_SRC
python3 - <<'PYEOF'
import os
import re
import yaml

LOGIN = os.environ["LOGIN"]
HASH = os.environ["HASH"]
DOMAIN = os.environ["DOMAIN"]
YAML_SRC = os.environ["YAML_SRC"]
NGINX_SRC = os.environ["NGINX_SRC"]
GEN_OUT = os.environ["GEN_OUT"]
MAP_TMP = os.environ["MAP_TMP"]

# ------------------------- 5/6: users + tls -------------------------
with open(YAML_SRC, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

cfg["users"] = [{"name": LOGIN, "password": HASH}]

tls = cfg.setdefault("tls", {})
tls["enabled"] = True
tls["server_name"] = DOMAIN
tls["force_https"] = False
tls["certificate_path"] = "/opt/certs/fullchain.pem"
tls["private_key_path"] = "/opt/certs/privkey.pem"

# ------------------------- 7: filtering.rewrites ---------------------
rewrites = []
with open(GEN_OUT, "r", encoding="utf-8") as f:
    src = f.read()

cur = None
in_rewrites = False
for raw in src.splitlines():
    line = raw.rstrip()
    if "--- Adguard rewrites ---" in line:
        in_rewrites = True
        continue
    if not in_rewrites:
        continue
    m = re.match(r'\s*-\s+domain:\s*"([^"]*)"', line)
    if m:
        cur = {"domain": m.group(1)}
        continue
    m = re.match(r'\s*answer:\s*(\S+)', line)
    if m and cur is not None:
        cur["answer"] = m.group(1)
        continue
    m = re.match(r'\s*enabled:\s*(\S+)', line)
    if m and cur is not None:
        cur["enabled"] = m.group(1).lower() == "true"
        rewrites.append(cur)
        cur = None

assert rewrites, "rewrites не распознаны из генератора"
cfg.setdefault("filtering", {})["rewrites"] = rewrites

with open(YAML_SRC, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False,
                   allow_unicode=True, width=10**9)
print(f"YAML: users.name={LOGIN}, tls.enabled=True, "
      f"server_name={DOMAIN}, rewrites={len(rewrites)}")

# ------------------------- 7: nginx map ------------------------------
with open(NGINX_SRC, "r", encoding="utf-8") as f:
    text = f.read()

if "dns.example.com" in text:
    text = text.replace("dns.example.com", DOMAIN)
    print(f"NGINX: dns.example.com -> {DOMAIN}")

with open(MAP_TMP, "r", encoding="utf-8") as f:
    entries = [l for l in f.read().splitlines() if l.strip()]

marker = "### --- NGINX map entries ---"
if marker in text:
    text = text.replace(marker, "\n".join(entries))
    print(f"NGINX: вставлено map-записей: {len(entries)}")
else:
    raise SystemExit("Маркер '### --- NGINX map entries ---' не найден в nginx.conf")

with open(NGINX_SRC, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF

# ============================================================================
# 8. Копия nginx/nginx.conf -> /etc/nginx/nginx.conf (с резервной копией)
# ============================================================================
BK="nginx.conf.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$NGINX_ETC" "/etc/nginx/$BK"
log "Резервная копия: /etc/nginx/$BK"
cp -a "$NGINX_SRC" "$NGINX_ETC"
log "Установлен: $NGINX_ETC"

# ============================================================================
# 9. Проверка синтаксиса и перезапуск nginx
# ============================================================================
if nginx -t; then
    log "nginx -t: OK"
    systemctl reload nginx && log "nginx reload: OK" \
        || { systemctl restart nginx && log "nginx restart: OK"; }
else
    warn "nginx -t НЕ прошёл — откат к резервной копии."
    cp -a "/etc/nginx/$BK" "$NGINX_ETC"
    nginx -t
    die "Конфиг откачен; исправьте map-записи/nginx.conf и повторите."
fi

# ============================================================================
# 10. Установка AdGuardHome.yaml и запуск контейнера
# ============================================================================
mkdir -p "$ADGUARD_DIR/conf"
cp -a "$YAML_SRC" "$YAML_DST"
log "Конфиг AdGuard Home: $YAML_DST"
cd "$ADGUARD_DIR"
if command -v docker >/dev/null; then
    docker compose up -d || docker-compose up -d
else
    die "docker не установлен"
fi
sleep 5
docker ps --filter name=adguardhome --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

log "Готово. Проверка TLS (локально):"
curl -sk --max-time 10 -o /dev/null -w "https://127.0.0.1:9443 -> HTTP %{http_code}\n" https://127.0.0.1:9443/ || \
    warn "HTTPS-проверка не ответила (возможно, DoH ещё поднимается)."

echo
echo "=== Итог ==="
echo "  Домен/SNI:        $DOMAIN"
echo "  Сертификат:      $CERT_DIR"
echo "  Логин админки:   $LOGIN"
echo "  Map-записей:     $(wc -l < "$MAP_TMP")"
echo "  Rewrites:        $(($(grep -c '^\s*- domain:' "$GEN_OUT")))"
echo "  nginx.conf:      $NGINX_ETC (бэкап: /etc/nginx/$BK)"
echo "  AdGuard конфиг:  $YAML_DST"
