#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/seafile"
DATA_DIR="/opt/seafile-data"
DB_DIR="/opt/seafile-mysql/db"

log_info() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

if ! command -v docker >/dev/null 2>&1; then
  log_info "Installation de Docker Engine et Docker Compose sur Debian 12..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl gnupg
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
fi

if [ -n "$SUDO" ] && id -nG "${USER:-zeus}" | grep -qvE '\bdocker\b'; then
  $SUDO usermod -aG docker "${USER:-zeus}" || true
fi

log_info "Preparation des repertoires persistants..."
$SUDO mkdir -p "$APP_DIR" "$DATA_DIR" "$DB_DIR"

VM_IP="$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
VM_IP="${VM_IP:-127.0.0.1}"

if [ ! -f "$APP_DIR/.env" ]; then
  log_info "Creation du fichier d'environnement $APP_DIR/.env..."
  JWT_KEY="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
  cat <<EOF | $SUDO tee "$APP_DIR/.env" >/dev/null
SEAFILE_IMAGE=seafileltd/seafile-mc:latest
SEAFILE_DB_IMAGE=mariadb:10.11
SEAFILE_REDIS_IMAGE=redis:7-alpine
SEAFILE_VOLUME=$DATA_DIR
SEAFILE_MYSQL_VOLUME=$DB_DIR
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=SeafileRootPass2026!
SEAFILE_MYSQL_DB_HOST=db
SEAFILE_MYSQL_DB_PORT=3306
SEAFILE_MYSQL_DB_USER=seafile
SEAFILE_MYSQL_DB_PASSWORD=SeafileDbPass2026!
SEAFILE_MYSQL_DB_CCNET_DB_NAME=ccnet_db
SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=seafile_db
SEAFILE_MYSQL_DB_SEAHUB_DB_NAME=seahub_db
INIT_SEAFILE_ADMIN_EMAIL=admin@example.local
INIT_SEAFILE_ADMIN_PASSWORD=SeafileAdminPass2026!
SEAFILE_SERVER_HOSTNAME=$VM_IP
SEAFILE_SERVER_PROTOCOL=http
CACHE_PROVIDER=redis
REDIS_HOST=redis
REDIS_PORT=6379
JWT_PRIVATE_KEY=$JWT_KEY
EOF
  $SUDO chmod 600 "$APP_DIR/.env"
fi

log_info "Ecriture de la configuration fonctionnelle $APP_DIR/docker-compose.yml..."
cat <<'EOF' | $SUDO tee "$APP_DIR/docker-compose.yml" >/dev/null
services:
  db:
    image: ${SEAFILE_DB_IMAGE:-mariadb:10.11}
    container_name: seafile-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      MYSQL_LOG_CONSOLES: "true"
    volumes:
      - ${SEAFILE_MYSQL_VOLUME:-/opt/seafile-mysql/db}:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "127.0.0.1", "--silent"]
      interval: 5s
      timeout: 5s
      retries: 20

  redis:
    image: ${SEAFILE_REDIS_IMAGE:-redis:7-alpine}
    container_name: seafile-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]

  seafile:
    image: ${SEAFILE_IMAGE:-seafileltd/seafile-mc:latest}
    container_name: seafile
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ${SEAFILE_VOLUME:-/opt/seafile-data}:/shared
    environment:
      DB_HOST: db
      DB_ROOT_PASSWD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      SEAFILE_MYSQL_DB_HOST: db
      SEAFILE_MYSQL_DB_PORT: ${SEAFILE_MYSQL_DB_PORT:-3306}
      SEAFILE_MYSQL_DB_USER: ${SEAFILE_MYSQL_DB_USER:-seafile}
      SEAFILE_MYSQL_DB_PASSWORD: ${SEAFILE_MYSQL_DB_PASSWORD}
      SEAFILE_MYSQL_DB_CCNET_DB_NAME: ${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}
      SEAFILE_MYSQL_DB_SEAFILE_DB_NAME: ${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}
      SEAFILE_MYSQL_DB_SEAHUB_DB_NAME: ${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}
      INIT_SEAFILE_ADMIN_EMAIL: ${INIT_SEAFILE_ADMIN_EMAIL:-admin@example.local}
      INIT_SEAFILE_ADMIN_PASSWORD: ${INIT_SEAFILE_ADMIN_PASSWORD}
      SEAFILE_SERVER_HOSTNAME: ${SEAFILE_SERVER_HOSTNAME:-127.0.0.1}
      SEAFILE_SERVER_PROTOCOL: ${SEAFILE_SERVER_PROTOCOL:-http}
      CACHE_PROVIDER: ${CACHE_PROVIDER:-redis}
      REDIS_HOST: ${REDIS_HOST:-redis}
      REDIS_PORT: ${REDIS_PORT:-6379}
      JWT_PRIVATE_KEY: ${JWT_PRIVATE_KEY}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
EOF

log_info "Demarrage de la pile Seafile..."
cd "$APP_DIR"
$SUDO docker compose up -d

log_info "Verification rapide de la disponibilite HTTP..."
for _ in $(seq 1 20); do
  if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ | grep -qE "^(200|301|302)$"; then
    log_info "Seafile repond correctement sur http://127.0.0.1/"
    exit 0
  fi
  sleep 3
done

log_info "Deploiement lance ; verifiez 'sudo docker compose ps' et 'sudo docker logs seafile' si besoin."