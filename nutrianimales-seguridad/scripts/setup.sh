#!/usr/bin/env bash
# =====================================================================
#  setup.sh — prepara el proyecto antes de "docker compose up"
#  - Crea .env con contraseñas aleatorias (chmod 600)       [hardening #2]
#  - Crea ./data/* con chmod 700 y el dueño correcto         [hardening #10]
#  - Genera el certificado TLS autofirmado de Nginx          [hardening #9]
#  Uso:  ./scripts/setup.sh      (pide sudo para chown de volúmenes)
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

rnd() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }

# ---------- 1. .env ----------
if [[ ! -f .env ]]; then
  echo "[+] Creando .env con contraseñas aleatorias"
  cp .env.example .env
  for v in POSTGRES_PASSWORD AGENTE_IA_PASSWORD MONITOR_PASSWORD GERENTE_DB_PASSWORD \
           TI_DB_PASSWORD AUDITOR_DB_PASSWORD N8N_PASSWORD MONITOR_WEBHOOK_TOKEN PGADMIN_PASSWORD; do
    sed -i "s|^${v}=.*|${v}=$(rnd 24)|" .env
  done
  sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$(rnd 40)|" .env
  echo "    -> Edite .env y coloque TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID y GROQ_API_KEY reales."
else
  echo "[=] .env ya existe, no se sobrescribe"
fi
chmod 600 .env
ls -la .env

# ---------- 2. Volúmenes ----------
echo "[+] Creando volúmenes con permisos restringidos"
mkdir -p data/postgres data/n8n data/pgadmin backups
sudo chown 999:999   data/postgres      # usuario postgres de la imagen
sudo chown 1000:1000 data/n8n           # usuario node (n8n)
sudo chown 5050:5050 data/pgadmin       # usuario pgadmin
sudo chmod 700 data/postgres data/n8n data/pgadmin
chmod 700 backups
sudo ls -la data

# ---------- 3. Certificado de Nginx ----------
if [[ ! -f nginx/certs/nginx.crt ]]; then
  echo "[+] Generando certificado autofirmado para Nginx"
  mkdir -p nginx/certs
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -subj "/C=CR/O=NutriAnimales S.A./CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -keyout nginx/certs/nginx.key -out nginx/certs/nginx.crt
  chmod 644 nginx/certs/nginx.crt
  chmod 600 nginx/certs/nginx.key   # el proceso maestro de nginx (root) la lee igual
fi

# ---------- 4. Scripts ejecutables ----------
chmod +x scripts/*.sh host-monitor/*.sh ataques/*.sh postgres/init/*.sh 2>/dev/null || true

echo
echo "Listo. Siguiente paso:  docker compose up -d --build"
