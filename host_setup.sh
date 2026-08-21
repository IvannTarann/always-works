#!/usr/bin/env bash
# HOST — помощник настройки для уже существующего VPS
# Пароли не спрашивает и не сохраняет.

set -Eeuo pipefail

WORK_DIR="/root/host-xhttp-setup"
PORT_DEFAULT="2054"
DOMAIN_DEFAULT="izjrkobh.killbill.site"

blue() { printf '\033[1;34m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
line() { printf '%s\n' '------------------------------------------------------------'; }
pause() { read -r -p "Нажмите Enter, чтобы продолжить..." _; }

ask() {
  prompt="$1"
  default="$2"
  answer=""
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " answer
    if [ -n "$answer" ]; then printf '%s' "$answer"; else printf '%s' "$default"; fi
  else
    while [ -z "$answer" ]; do
      read -r -p "$prompt: " answer
      [ -z "$answer" ] && yellow "Это значение нужно указать."
    done
    printf '%s' "$answer"
  fi
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    red "Запустите так: sudo bash $0"
    exit 1
  fi
}

make_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

make_subid() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }

write_files() {
  mkdir -p "$WORK_DIR"
  umask 077

  cat > "$WORK_DIR/inbound-test.json" <<JSON
{
  "listen": "",
  "port": PORT_VALUE,
  "protocol": "vless",
  "tag": "TEST-PORT_VALUE",
  "settings": {
    "clients": [{
      "id": "UUID_VALUE",
      "email": "EMAIL_VALUE",
      "flow": "",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": 0,
      "subId": "SUBID_VALUE",
      "comment": "",
      "reset": 0
    }],
    "decryption": "none",
    "encryption": "none"
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic", "fakedns"]
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": {
      "path": "/p",
      "host": "",
      "mode": "packet-up",
      "xPaddingBytes": "48-256",
      "xPaddingObfsMode": true,
      "xPaddingKey": "q",
      "xPaddingHeader": "",
      "xPaddingPlacement": "query",
      "xPaddingMethod": "tokenish",
      "sessionIDPlacement": "query",
      "sessionIDKey": "sid",
      "sessionIDTable": "",
      "sessionIDLength": "",
      "seqPlacement": "query",
      "seqKey": "offset",
      "uplinkDataPlacement": "",
      "uplinkDataKey": "",
      "scMaxEachPostBytes": "262144-786432",
      "noSSEHeader": false,
      "scMaxBufferedPosts": 30,
      "scStreamUpServerSecs": "20-80",
      "serverMaxHeaderBytes": 0,
      "uplinkHTTPMethod": "DELETE",
      "headers": {},
      "scMinPostsIntervalMs": "0",
      "uplinkChunkSize": 0,
      "noGRPCHeader": false,
      "enableXmux": false
    },
    "security": "none"
  }
}
JSON

  sed -i \
    -e "s/PORT_VALUE/$PORT/g" \
    -e "s/UUID_VALUE/$UUID/g" \
    -e "s/EMAIL_VALUE/$EMAIL/g" \
    -e "s/SUBID_VALUE/$SUB_ID/g" \
    "$WORK_DIR/inbound-test.json"

  cat > "$WORK_DIR/.htaccess" <<'HTACCESS'
RewriteEngine On
RewriteRule ^p/?$ p.php [L]
HTACCESS

  cat > "$WORK_DIR/p.php" <<'PHP'
<?php
$target = "http://__VPS_IP__:__PORT__/p";

while (ob_get_level() > 0) { @ob_end_flush(); }
@ini_set('output_buffering', '0');
@ini_set('zlib.output_compression', '0');
@ini_set('implicit_flush', '1');
set_time_limit(0);
ignore_user_abort(true);

if (!empty($_SERVER['QUERY_STRING'])) {
    $target .= '?' . $_SERVER['QUERY_STRING'];
}

$method = $_SERVER['REQUEST_METHOD'];
$body = file_get_contents('php://input');
$headers = function_exists('getallheaders') ? getallheaders() : [];
$curl_headers = [];

foreach ($headers as $key => $value) {
    $lower = strtolower($key);
    if ($lower === 'host' || $lower === 'content-length' || $lower === 'connection') {
        continue;
    }
    $curl_headers[] = $key . ': ' . $value;
}

$curl_headers[] = 'Host: __DOMAIN__';
$curl_headers[] = 'X-Forwarded-Proto: https';
$curl_headers[] = 'Connection: keep-alive';

$ch = curl_init($target);
curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
curl_setopt($ch, CURLOPT_HTTPHEADER, $curl_headers);
curl_setopt($ch, CURLOPT_FOLLOWLOCATION, false);
curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 10);
curl_setopt($ch, CURLOPT_TIMEOUT, 0);
curl_setopt($ch, CURLOPT_TCP_KEEPALIVE, 1);
curl_setopt($ch, CURLOPT_TCP_KEEPIDLE, 20);
curl_setopt($ch, CURLOPT_TCP_KEEPINTVL, 10);
curl_setopt($ch, CURLOPT_HEADER, false);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, false);

if ($body !== false && strlen($body) > 0) {
    curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
}

curl_setopt($ch, CURLOPT_HEADERFUNCTION, function ($curl, $header) {
    $len = strlen($header);
    $line = trim($header);
    if ($line === '') return $len;

    if (stripos($line, 'HTTP/') === 0) {
        if (preg_match('/HTTP\/\S+\s+(\d+)/', $line, $m)) {
            http_response_code((int)$m[1]);
        }
        return $len;
    }

    $parts = explode(':', $header, 2);
    if (count($parts) === 2) {
        $name = trim($parts[0]);
        $value = trim($parts[1]);
        $lower = strtolower($name);

        if ($lower !== 'transfer-encoding' &&
            $lower !== 'content-length' &&
            $lower !== 'connection') {
            header($name . ': ' . $value, false);
        }
    }
    return $len;
});

curl_setopt($ch, CURLOPT_WRITEFUNCTION, function ($curl, $data) {
    echo $data;
    if (function_exists('ob_flush')) { @ob_flush(); }
    flush();
    return strlen($data);
});

$result = curl_exec($ch);

if ($result === false) {
    if (!headers_sent()) { http_response_code(502); }
    error_log('XHTTP proxy curl error: ' . curl_error($ch));
}

curl_close($ch);
PHP

  sed -i \
    -e "s/__VPS_IP__/$VPS_IP/g" \
    -e "s/__PORT__/$PORT/g" \
    -e "s/__DOMAIN__/$DOMAIN/g" \
    "$WORK_DIR/p.php"

  cat > "$WORK_DIR/README.txt" <<TXT
HOST — файлы для настройки

VPS: $VPS_IP
Порт TEST: $PORT
UUID: $UUID
subId: $SUB_ID
Домен REG.RU: $DOMAIN

1. inbound-test.json вставьте в 3x-ui.
2. p.php и .htaccess загрузите в папку сайта REG.RU.
3. Сначала проверьте прямой адрес VPS:$PORT.
4. Потом проверьте домен REG.RU:443.
5. Пароли в этих файлах не хранятся.
TXT

  chmod 600 "$WORK_DIR/inbound-test.json" "$WORK_DIR/p.php"
}

manual_steps() {
  line
  blue "1. 3x-ui — это делаем на VPS"
  cat <<TXT
Откройте 3x-ui → Входящие → создайте TEST inbound.
Порт: $PORT
Протокол: VLESS
Транспорт: XHTTP
Путь: /p
Режим: packet-up
Uplink method: DELETE
Security на origin: none

Файл для вставки:
$WORK_DIR/inbound-test.json

UUID клиента:
$UUID
TXT

  line
  blue "2. REG.RU — это делаем НЕ на VPS"
  cat <<TXT
В DNS направьте $DOMAIN на shared hosting REG.RU.
Включите SSL/Let's Encrypt.
В папке сайта сначала сохраните старый p.php как p.php.bak2.
Загрузите туда:
$WORK_DIR/p.php
$WORK_DIR/.htaccess
TXT

  line
  blue "3. Happ"
  cat <<TXT
Обновите подписку.
Сначала проверьте TEST напрямую:
  адрес $VPS_IP
  порт $PORT
Потом проверьте через домен:
  $DOMAIN:443
Сравните пинг и скорость.
TXT
}

check_vps() {
  line
  blue "Проверка VPS"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | grep ":$PORT " || yellow "Порт $PORT пока не слушается. Сначала сохраните inbound в 3x-ui."
  fi
  if command -v nginx >/dev/null 2>&1; then
    nginx -t 2>&1 || true
  else
    yellow "nginx не найден. Это нормально, если HTTPS заканчивается на REG.RU."
  fi
}

show_logs() {
  line
  blue "Команды диагностики"
  cat <<TXT
ss -ltnp | grep ':$PORT'
journalctl -u x-ui -n 100 --no-pager
journalctl -u xray -n 100 --no-pager
tail -n 100 /var/log/nginx/access.log
tail -n 100 /var/log/nginx/error.log
curl -vk -i https://$DOMAIN/p
curl -v --connect-timeout 5 http://$VPS_IP:$PORT/
TXT
}

main() {
  require_root
  blue "HOST — простой помощник настройки"
  echo "У вас уже есть VPS. Скрипт создаст готовые файлы и подскажет ручные шаги."
  line

  VPS_IP="$(ask "IP вашего VPS" "")"
  DOMAIN="$(ask "Домен REG.RU" "$DOMAIN_DEFAULT")"
  PORT="$(ask "Порт TEST" "$PORT_DEFAULT")"
  EMAIL="$(ask "Имя клиента" "user1")"
  UUID="$(make_uuid)"
  SUB_ID="$(make_subid)"

  write_files
  green "Готово. Файлы лежат в $WORK_DIR"
  echo "UUID: $UUID"
  echo "subId: $SUB_ID"
  check_vps
  manual_steps

  echo
  read -r -p "Вы уже сохранили inbound в 3x-ui? [y/N]: " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then check_vps; fi

  show_logs
  green "Скрипт завершён. Сначала добейтесь работы TEST, потом проверяйте REG.RU."
}

main "$@"
