# Guía para el informe y las capturas — BCD 9220

Mapa de cada ítem del **Checklist de Evaluación (sección 13)** y la
**rúbrica (sección 14)** hacia el comando que genera su evidencia. El informe
final debe tener 15–20 páginas con capturas reales.

## Hardening y Docker (12 puntos → sección 10)

| Punto | Comando para la captura |
|-------|-------------------------|
| 1 no-root | `docker compose exec n8n whoami` → `node` |
| 2 .env 600 | `ls -la .env` → `-rw-------` |
| 3 red aislada | `docker network inspect nutrianimales-net` |
| 4 sin puerto PG | `docker compose ps` → solo Nginx en 8080/8443 |
| 5 scram | `docker compose exec postgres psql -U postgres -c "SHOW password_encryption;"` |
| 6 SSL PG | `... -c "SHOW ssl;"` → `on` |
| 7 agente_ia RO | ver README §1 (INSERT → permission denied) |
| 8 headers | `curl -kI https://localhost:8443` → HSTS, X-Frame-Options, CSP |
| 9 cert Nginx | abrir en el navegador → candado HTTPS |
| 10 volúmenes | `ls -la data` → `drwx------` |
| 11 logs | `docker compose exec postgres psql -U postgres -c "SHOW log_min_duration_statement;"` |
| 12 baseline | `docker compose exec postgres psql -U postgres -d nutrianimales_db -c "SELECT * FROM pg_settings_baseline;"` |

## Matriz de riesgos y RBAC

- 2.1 Matriz de 5 amenazas → tabla de la sección 2 del enunciado (va en el informe).
- 2.2 3 roles: `... -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'rol_%';"`
- 2.3 gerente NO ve auditoría:
  `docker compose exec postgres bash -lc 'PGPASSWORD=$GERENTE_DB_PASSWORD psql -U gerente_db -d nutrianimales_db -c "SELECT * FROM auditoria_datos;"'`
  → `permission denied` / `does not exist`.
- 2.4 Inventario de secretos → sección 8 del README.

## Triggers de auditoría

- 3.1 `\d auditoria_datos`
- 3.2 `SELECT proname FROM pg_proc WHERE proname='fn_auditoria';`
- 3.3 `SELECT trigger_name, event_object_table FROM information_schema.triggers WHERE trigger_name LIKE 'trg_auditoria%';`
- 3.4 Demostrar el trigger:
  ```bash
  docker compose exec postgres psql -U postgres -d nutrianimales_db \
    -c "UPDATE ventas SET estado='anulada' WHERE id=1;" \
    -c "SELECT usuario, operacion, valor_antes->>'estado' AS antes, valor_nuevo->>'estado' AS despues
        FROM auditoria_datos WHERE tabla='ventas' ORDER BY id DESC LIMIT 1;"
  ```

## 17 alertas (capturas en Telegram)

Dispara cada categoría y captura el mensaje que llega al chat. Para forzar
una alerta concreta sin esperar al ciclo de un minuto:

```bash
docker compose exec postgres psql -U postgres -d nutrianimales_db \
  -c "SELECT texto FROM monitor.ejecutar_chequeo('R1');"
```

- R1: `... -c "SELECT pg_sleep(1.3);"` y esperar el ciclo.
- R2: abrir 12 conexiones (`for i in $(seq 12); do ... pg_sleep(8) & done`).
- R3: en `monitor.config` poner `horario_fin` = hora actual; conectar.
- R4: `./ataques/a1_fuerza_bruta_ssh.sh`.
- R5/H5: `ALTER SYSTEM SET password_encryption='md5'; SELECT pg_reload_conf();` (y revertir con `RESET`).
- H2: editar `postgres/conf/pg_hba.conf` (agregar una línea) y esperar.
- H3: `./ataques/a4_escalada_privilegios.sh`.
- H4: conectar desde una IP fuera de `172.28.0.0/16`.
- H1: `./ataques/a3_abrir_puerto.sh`.
- D1/D6: crear una tabla de prueba y hacer DELETE/UPDATE sin WHERE (ver §5 del enunciado).
- D2: insertar > 20 % de filas en una tabla en menos de 30 min.
- D3: no correr `backup.sh` por > 24 h (o adelantar el reloj de la demo).
- D4: insertar > 5 clientes con correo repetido.
- D5: abrir dos transacciones que se bloqueen > 30 s.
- D7: `./ataques/a5_exfiltracion.sh`.

## 5 ataques (sección 8) y gestión de secretos (sección 9)

- A1–A5: ejecutar los scripts de `ataques/` y capturar comando + alerta + auditoría + respuesta.
- 6.1 Rotación de API key → README §8.
- 6.2 `.env`: `ls -la .env`.
- 6.3 `.gitignore`: `cat .gitignore | grep .env`.

## Entregables finales

- ZIP del proyecto (este árbol completo, sin `.env`, `data/` ni `backups/`).
- README que levanta el sistema en < 5 min (sección 1).
- Informe 15–20 páginas con capturas reales.
- Exposición de 15 min con demo en vivo; participan los 5 integrantes.
