# Escenarios de ataque simulado (A1–A5)

Cada script ejecuta uno de los 5 ataques obligatorios de la sección 8 y
te dice qué alerta debe dispararse. Para la evidencia del informe, captura
en cada uno: (1) el comando, (2) la alerta en Telegram con hora, (3) la
fila en `auditoria_datos` cuando aplique, y (4) la respuesta tomada.

| Script | Ataque | Alerta esperada | Tiempo |
|--------|--------|-----------------|--------|
| `a1_fuerza_bruta_ssh.sh`   | A1 Fuerza bruta SSH          | R4 | < 5 min |
| `a2_sql_injection_bot.sh`  | A2 SQL Injection vía Telegram| Bloqueo N8N (sin alerta) + auditoría | inmediato |
| `a3_abrir_puerto.sh`       | A3 Apertura de puerto 5432   | H1 | < 5 min |
| `a4_escalada_privilegios.sh` | A4 GRANT a agente_ia       | H3 | < 5 min |
| `a5_exfiltracion.sh`       | A5 Exfiltración SELECT masivo| D7 | < 5 min |

Como el motor de alertas corre cada minuto, puedes forzar la evaluación
inmediata de una alerta concreta con:

```bash
docker compose exec -T postgres \
  psql -U monitor_n8n -d nutrianimales_db \
  -c "SELECT codigo, severidad, texto FROM monitor.ejecutar_chequeo('H3');"
```

(Para `monitor_n8n` necesitas su contraseña; usa `-U postgres` con
`docker compose exec` si prefieres no exponerla.)

> ⚠️ Solo para el entorno de laboratorio de este proyecto. No ejecutar
> contra sistemas de terceros.
