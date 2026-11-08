# NutriAnimales S.A. — Monitoreo, Seguridad y Hardening de Base de Datos

**Lead University · BCD 9220 — Seguridad de Sistemas Digitales · III Cuatrimestre 2026**
Stack: Docker · PostgreSQL 16 · N8N · Telegram · Groq · Nginx · pgAdmin

Sistema de seguridad integral para la base de datos transaccional de
NutriAnimales S.A.: **17 alertas automáticas**, **triggers de auditoría**,
**RBAC de 3 roles**, **12 puntos de hardening** y **5 escenarios de ataque**
reproducibles, todo orquestado con N8N y notificado por Telegram.

---

## 1. Levantar el sistema en menos de 5 minutos

Requisitos: Docker + Docker Compose v2, `openssl`, y `node` (solo para el
script de demostración A2). En Linux/WSL o macOS.

```bash
# 1. Entrar al proyecto
cd nutrianimales-seguridad

# 2. Preparar .env (contraseñas aleatorias), volúmenes y certificado de Nginx
./scripts/setup.sh

# 3. Editar .env y colocar SOLO tres valores reales:
#      TELEGRAM_BOT_TOKEN   (de @BotFather)
#      TELEGRAM_CHAT_ID     (tu chat o grupo; los grupos empiezan con -100)
#      GROQ_API_KEY         (de console.groq.com)
nano .env

# 4. Levantar todo
docker compose up -d --build

# 5. Verificar que todo está 'running' y que PostgreSQL NO expone el 5432
docker compose ps
```

Accesos (todo detrás de Nginx con HTTPS, **puerto 5432 nunca expuesto**):

| Servicio | URL |
|----------|-----|
| N8N (editor de flujos) | `https://localhost:8443/` |
| pgAdmin | `https://localhost:8443/pgadmin/` |
| HTTP → redirige a HTTPS | `http://localhost:8080/` |

> El certificado es autofirmado: el navegador mostrará una advertencia la
> primera vez (es esperado en el hardening #9). Acéptala para continuar.

### Paso a paso en Windows 10/11 (WSL2 + Docker Desktop)

El proyecto es de Linux (scripts `bash`, `sudo chown`, `openssl`), así que en
Windows se corre **dentro de WSL2**, no en PowerShell.

**Paso 0 — Requisitos (una sola vez).** En PowerShell como administrador:

```powershell
wsl --install -d Ubuntu
```

Reinicia si lo pide. Instala/abre **Docker Desktop** y activa
`Settings → Resources → WSL Integration → Ubuntu (ON)`. Comprueba dentro de
Ubuntu: `docker compose version`.

**Paso 1 — Copiar el proyecto a WSL** (evita problemas de permisos y de saltos
de línea CRLF):

```bash
cp -r "/mnt/c/Users/Gabo/Desktop/ULEAD/SEGURIDAD/nutrianimales-seguridad" ~/
cd ~/nutrianimales-seguridad
sudo apt-get update && sudo apt-get install -y dos2unix
find . -name "*.sh" -exec dos2unix {} \; -exec chmod +x {} \;
```

**Paso 2 — Preparar `.env`, volúmenes y certificado** (pedirá `sudo` para el
dueño de los volúmenes; es normal):

```bash
./scripts/setup.sh
```

**Paso 3 — Colocar los 3 secretos reales** (`nano .env`): `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID` y `GROQ_API_KEY`. Los demás ya quedaron aleatorios. Si solo
quieres revisar la base y el hardening, puedes dejarlos vacíos: Postgres,
Nginx, N8N y pgAdmin levantan igual (solo faltarán las alertas a Telegram y el
bot con IA). Guarda con `Ctrl+O`, `Enter`, y sal con `Ctrl+X`.

**Paso 4 — Levantar todo** (la primera vez tarda: construye Postgres y descarga
las imágenes; al crear la BD se ejecutan solos los scripts `init/01..07`):

```bash
docker compose up -d --build
docker compose ps
```

Verifica que los 5 servicios están `running`/`healthy` y que `postgres` **no**
publica el puerto 5432 (hardening #4).

**Paso 5 — Abrir los servicios** (acepta el aviso del certificado autofirmado
la primera vez):

| Servicio | URL |
|----------|-----|
| N8N (editor de flujos) | `https://localhost:8443/` |
| pgAdmin | `https://localhost:8443/pgadmin/` |
| HTTP → redirige a HTTPS | `http://localhost:8080/` |

Para ver las contraseñas generadas cuando las necesites:

```bash
grep -E "N8N_PASSWORD|PGADMIN_PASSWORD" .env
```

**Paso 6 — Configurar N8N (una sola vez):**

1. Entra a `https://localhost:8443/` y crea la cuenta propietaria con el
   `N8N_PASSWORD` del `.env`.
2. **Credentials** → crea estas, con el nombre exacto (los flujos ya las usan):
   - **PG Monitor (monitor_n8n)** — Postgres: host `postgres`, puerto `5432`,
     base `nutrianimales_db`, usuario `monitor_n8n`, pass = `MONITOR_PASSWORD`,
     SSL `allow`.
   - **PG Agente IA (agente_ia)** — igual, usuario `agente_ia`,
     pass = `AGENTE_IA_PASSWORD`.
   - **Telegram Bot NutriAnimales** — Telegram: access token = `TELEGRAM_BOT_TOKEN`.
   - **Groq API** — Header Auth: nombre `Authorization`, valor `Bearer TU_GROQ_API_KEY`.
   - **Token Webhook Host** — Header Auth: nombre `X-Webhook-Token`,
     valor = `MONITOR_WEBHOOK_TOKEN`.
3. **Workflows → Import from File** e importa los tres:
   `n8n/workflows/01_alertas_bd.json`, `02_alertas_host.json`, `03_bot_telegram.json`.
4. Abre cada flujo, confirma que cada nodo tiene su credencial y **actívalo**.
5. Autoriza tu usuario del bot:
   ```bash
   docker compose exec postgres psql -U postgres -d nutrianimales_db -c \
   "INSERT INTO monitor.usuarios_bot(chat_id,nombre,rol) VALUES (TU_CHAT_ID,'Gerente General','gerente');"
   ```

Con esto el sistema queda levantado y operando. Los detalles ampliados de N8N
están en la sección 2.

**Comandos útiles:**

```bash
docker compose logs -f postgres   # ver logs de un servicio
docker compose restart n8n        # reiniciar solo n8n
docker compose down               # apagar (conserva ./data)
docker compose down -v            # apagar y BORRAR datos (empezar de cero)
```

### Comprobación rápida del hardening

```bash
# PostgreSQL no está en la lista de puertos publicados -> solo Nginx (8080/8443)
docker compose ps

# scram-sha-256 y SSL activos
docker compose exec postgres psql -U postgres -d nutrianimales_db \
  -c "SHOW password_encryption;" -c "SHOW ssl;"

# agente_ia es de solo lectura
docker compose exec postgres bash -lc \
  'PGPASSWORD=$AGENTE_IA_PASSWORD psql -U agente_ia -d nutrianimales_db \
   -c "INSERT INTO gastos(categoria,descripcion,monto,fecha,aprobado_por) VALUES (1,2,3,now(),4);"'
#  -> ERROR: cannot execute INSERT in a read-only transaction
```

---

## 2. Configurar N8N (una sola vez)

1. Abre `https://localhost:8443/`, crea la cuenta propietaria (usa el
   `N8N_PASSWORD` del `.env`).
2. **Credenciales** → crea estas, con exactamente estos nombres (los flujos
   ya las referencian):
   - **PG Monitor (monitor_n8n)** — Postgres. Host `postgres`, puerto `5432`,
     base `nutrianimales_db`, usuario `monitor_n8n`, contraseña = `MONITOR_PASSWORD`,
     SSL: `allow`.
   - **PG Agente IA (agente_ia)** — Postgres. Igual, usuario `agente_ia`,
     contraseña = `AGENTE_IA_PASSWORD`.
   - **Telegram Bot NutriAnimales** — Telegram. Access token = `TELEGRAM_BOT_TOKEN`.
   - **Groq API** — Header Auth. Nombre `Authorization`, valor `Bearer TU_GROQ_API_KEY`.
   - **Token Webhook Host** — Header Auth. Nombre `X-Webhook-Token`,
     valor = `MONITOR_WEBHOOK_TOKEN` del `.env`.
3. **Importar los flujos** (`Workflows → Import from File`):
   - `n8n/workflows/01_alertas_bd.json` — 16 alertas de BD, cada minuto.
   - `n8n/workflows/02_alertas_host.json` — alertas del host (H1, R4 SSH).
   - `n8n/workflows/03_bot_telegram.json` — bot de consultas para la gerencia.
4. Abre cada flujo, confirma que cada nodo tiene su credencial asignada y
   **actívalo** (Save → Publish/Active).
5. Autoriza a los usuarios del bot (RBAC de Telegram):

```bash
docker compose exec postgres psql -U postgres -d nutrianimales_db -c \
"INSERT INTO monitor.usuarios_bot(chat_id,nombre,rol) VALUES
 (TU_CHAT_ID,'Gerente General','gerente');"
```

### Monitor del host (H1 UFW + R4 SSH)

Estas dos fuentes viven fuera de PostgreSQL. Se instalan en el host con cron
(un paso, documentado en `host-monitor/cron.md`). Envían sus hallazgos al
webhook del flujo 02, que deduplica y notifica por Telegram.

> **Nota sobre la fuente de H1/R4-SSH.** El enunciado sugiere `Filebeat + Loki`
> para `ufw.log`. Este proyecto usa un enfoque equivalente y más liviano:
> `host-monitor/monitor_host.sh` compara el estado de UFW por hash y cuenta
> los fallos de SSH del journal, logrando la misma detección sin desplegar la
> pila de observabilidad. Si se prefiere Filebeat/Loki, el webhook del flujo
> 02 acepta igual el mismo payload JSON.

---

## 3. Las 17 alertas

El motor de detección vive **dentro de PostgreSQL** (esquema `monitor`), y
N8N solo lo invoca con el usuario de mínimo privilegio `monitor_n8n`:

```sql
SELECT * FROM monitor.ejecutar_chequeo('D7');   -- una alerta
```

Esto mantiene la lógica versionada, probada y fuera del alcance de N8N, y
**deduplica**: una misma alerta no se reenvía antes de `dedup_minutos` (60
por defecto). Umbrales y horarios se ajustan en la tabla `monitor.config`.

| # | Cat. | Alerta | Fuente | Sev. | Umbral |
|---|------|--------|--------|------|--------|
| R1 | Rendimiento | Consulta lenta | pg_stat_statements | Advertencia | > 1 s |
| R2 | Rendimiento | Saturación de conexiones | pg_stat_activity | Advertencia | > 10 |
| R3 | Rendimiento | Conexión en horario no laboral | pg_stat_activity | Crítica | 23:00–06:00 |
| R4 | Rendimiento | Autenticación fallida | log PG + SSH host | Crítica | > 5 / 10 min |
| R5 | Rendimiento | Cambio en postgresql.conf | pg_settings / pg_file_settings | Crítica | cualquiera |
| H1 | Hardening | Puerto/regla UFW modificada | host-monitor | Crítica | cualquiera |
| H2 | Hardening | pg_hba/postgresql.conf modificado | hash MD5 | Crítica | hash distinto |
| H3 | Hardening | GRANT a agente_ia | pg_roles + grants | Crítica | detectado |
| H4 | Hardening | IP fuera de red Docker | pg_stat_activity | Crítica | ∉ 172.28/16 |
| H5 | Hardening | SSL off / auth MD5 | pg_settings vs baseline | Crítica | ssl=off o md5 |
| D1 | Datos | DELETE masivo sin WHERE | pg_stat_statements | Crítica | > 100 filas |
| D2 | Datos | Crecimiento anormal de tabla | pg_stat_user_tables | Advertencia | > 20 % / 30 min |
| D3 | Datos | Backup obsoleto | tabla backups | Advertencia | > 24 h |
| D4 | Datos | Duplicados en tablas críticas | GROUP BY HAVING | Advertencia | > 5 |
| D5 | Datos | Bloqueo / deadlock | pg_locks + pg_stat_activity | Advertencia | > 30 s |
| D6 | Datos | UPDATE masivo sin WHERE | pg_stat_statements | Crítica | > 50 filas |
| D7 | Datos | Exfiltración (SELECT masivo) | pg_stat_statements | Crítica | > 1 000 filas |

Ver el estado de todas en cualquier momento:

```bash
./scripts/probar_alertas.sh
```

---

## 4. Los 5 ataques simulados (sección 8)

Scripts en `ataques/`. Cada uno dice qué capturar para el informe.

```bash
./ataques/a1_fuerza_bruta_ssh.sh      # -> R4
./ataques/a2_sql_injection_bot.sh     # -> bloqueo N8N + registro en auditoría
./ataques/a3_abrir_puerto.sh          # -> H1
./ataques/a4_escalada_privilegios.sh  # -> H3
./ataques/a5_exfiltracion.sh          # -> D7
```

A2 (inyección por el bot) se detiene con **defensa en profundidad**: el filtro
de entrada del flujo 03 bloquea el texto antes de que llegue a la IA o a la
base; además la consulta se ejecuta como `agente_ia`, de solo lectura, de modo
que una escritura sería rechazada por PostgreSQL aunque superara el filtro.

| Script | Ataque | Alerta esperada | Tiempo |
|--------|--------|-----------------|--------|
| `a1_fuerza_bruta_ssh.sh`     | A1 Fuerza bruta SSH           | R4 | < 5 min |
| `a2_sql_injection_bot.sh`    | A2 SQL Injection vía Telegram | Bloqueo N8N (sin alerta) + auditoría | inmediato |
| `a3_abrir_puerto.sh`         | A3 Apertura de puerto 5432    | H1 | < 5 min |
| `a4_escalada_privilegios.sh` | A4 GRANT a agente_ia          | H3 | < 5 min |
| `a5_exfiltracion.sh`         | A5 Exfiltración SELECT masivo | D7 | < 5 min |

Para la evidencia del informe, captura en cada ataque: (1) el comando, (2) la
alerta en Telegram con hora, (3) la fila en `auditoria_datos` cuando aplique y
(4) la respuesta tomada. Como el motor corre cada minuto, puedes forzar la
evaluación inmediata de una alerta concreta:

```bash
docker compose exec -T postgres \
  psql -U postgres -d nutrianimales_db \
  -c "SELECT codigo, severidad, texto FROM monitor.ejecutar_chequeo('H3');"
```

> ⚠️ Solo para el entorno de laboratorio de este proyecto. No ejecutar contra
> sistemas de terceros.

---

## 5. Estructura del proyecto

```
nutrianimales-seguridad/
├── docker-compose.yml          # 5 servicios + túnel opcional, red aislada
├── .env.example                # plantilla de secretos (sin valores reales)
├── .gitignore                  # .env, certs y data fuera del repo
├── scripts/
│   ├── setup.sh                # .env + volúmenes + certificado
│   ├── backup.sh               # respaldo + registro para D3
│   └── probar_alertas.sh       # evalúa las 16 alertas de BD
├── postgres/
│   ├── Dockerfile              # PG 16 + certificado TLS (hardening #6)
│   ├── conf/                   # postgresql.conf + pg_hba.conf endurecidos
│   └── init/                   # se ejecuta al crear la BD, en orden:
│       ├── 01_schema.sql           tablas del negocio + seguridad
│       ├── 02_seed.sql             datos sintéticos (2 000 clientes, 5 000 ventas)
│       ├── 03_auditoria.sql        triggers UPDATE/DELETE/INSERT/TRUNCATE
│       ├── 04_reportes.sql         vistas para la gerencia y el bot
│       ├── 05_monitor.sql          motor de las 17 alertas (esquema monitor)
│       ├── 06_baseline.sql         pg_settings_baseline + hashes de config
│       └── 07_roles_y_config.sh    RBAC (3 roles) + agente_ia + monitor_n8n
├── nginx/
│   └── nginx.conf              # HTTPS, headers de seguridad, rate-limit
├── n8n/
│   ├── generar_flujos.py       # genera 01 y 02
│   ├── generar_bot.py          # genera 03
│   └── workflows/*.json        # flujos importables
├── host-monitor/
│   ├── monitor_host.sh         # H1 (UFW) + R4 (SSH) -> webhook
│   └── cron.md                 # instalación en el host
├── ataques/                    # A1–A5
└── docs/
    └── guia_informe.md         # qué capturar para cada punto de la rúbrica
```

---

## 6. Hardening — los 12 puntos y dónde se cumplen

| # | Medida | Dónde |
|---|--------|-------|
| 1 | Usuario no-root en contenedores | `docker-compose.yml` (`user: "1000:1000"`, 5050) |
| 2 | Secretos en `.env` (chmod 600, gitignore) | `scripts/setup.sh`, `.gitignore` |
| 3 | Red Docker aislada | `nutrianimales-net` (`internal: true`) |
| 4 | PostgreSQL sin puerto expuesto | servicio `postgres` sin `ports:` |
| 5 | scram-sha-256 | `POSTGRES_INITDB_ARGS` + `postgresql.conf` |
| 6 | SSL/TLS en PostgreSQL | `postgres/Dockerfile` + `postgresql.conf` |
| 7 | agente_ia solo lectura | `07_roles_y_config.sh` (SELECT + read-only + timeout) |
| 8 | Headers de seguridad en Nginx | `nginx/nginx.conf` (HSTS, CSP, X-Frame-Options…) |
| 9 | Certificado SSL en Nginx | `scripts/setup.sh` (OpenSSL) |
| 10 | Volúmenes con permisos restringidos | `scripts/setup.sh` (chmod 700) |
| 11 | Logs de auditoría | `postgresql.conf` (`log_min_duration_statement`, `log_statement=ddl`) |
| 12 | Tabla pg_settings_baseline | `06_baseline.sql` |

---

## 7. RBAC — 3 roles (mínimo privilegio)

| Rol | Usuario | Puede | NO puede |
|-----|---------|-------|----------|
| Gerente | `gerente_db` | SELECT en `reportes.*` | ver tablas base ni auditoría |
| Admin TI | `ti_db` | SELECT en todo + INSERT en backups/alertas | modificar datos del negocio |
| Auditor | `auditor_db` | auditoría + estadísticas del servidor | ver datos del negocio |

Además, dos usuarios de servicio: `agente_ia` (bot, solo lectura) y
`monitor_n8n` (alertas, solo ejecuta la API del esquema `monitor`).
La tabla `auditoria_datos` es de **solo-agregar**: un trigger bloquea
cualquier UPDATE/DELETE/TRUNCATE sobre ella, incluso del superusuario.

---

## 8. Gestión de secretos y rotación

Inventario y procedimientos de revocación en `docs/guia_informe.md` (sección 9
del enunciado). Puntos clave:

- `.env` con `chmod 600`, en `.gitignore`, nunca al repositorio.
- N8N nunca lleva la API key en los nodos: siempre credenciales almacenadas,
  y `N8N_BLOCK_ENV_ACCESS_IN_NODE=true` impide que un nodo lea variables de entorno.
- Rotación: Groq y `N8N_PASSWORD` cada 90 días; contraseñas de PostgreSQL cada
  6 meses; cualquier secreto, de inmediato si se filtra.

Demostración de rotación de la API key de Groq (sección 9.3):

```bash
# 1. (simular filtración) borrar la key en console.groq.com
# 2. crear una key nueva
# 3. actualizar el valor en la credencial "Groq API" de N8N (o en .env si la lees de ahí)
# 4. reiniciar solo N8N, sin tocar la base de datos:
docker compose restart n8n
# 5. verificar: enviar una pregunta al bot de Telegram y recibir respuesta
```

---

## 9. Notas de compatibilidad (N8N 2.0)

Este proyecto asume N8N 2.x. Dos cambios de la 2.0 ya están contemplados:
`N8N_BLOCK_ENV_ACCESS_IN_NODE=true` (coincide con la política de secretos) y
la autenticación obligatoria del webhook (el flujo 02 usa Header Auth). El bot
y las alertas no usan el nodo *Execute Command*, así que no requieren
`NODES_INCLUDE`.

---

*Lead University · BCD 9220 Seguridad de Sistemas Digitales · III Cuatrimestre 2026 · Prof. Joshua Vargas Salas*
