#!/usr/bin/env python3
"""
Genera los flujos de N8N (JSON importables) de NutriAnimales S.A.

  01_alertas_bd.json    Cada minuto. 16 nodos Postgres, uno por alerta
                        (R1-R5, H2-H5, D1-D7) -> filtro -> Telegram.
  02_alertas_host.json  Webhook con token. Recibe H1 (UFW) y R4 (SSH)
                        desde host-monitor/monitor_host.sh.

Las credenciales NO van en los JSON: se asignan en N8N al importar.
Uso:  python3 n8n/generar_flujos.py
"""
import json
import uuid
from pathlib import Path

OUT = Path(__file__).parent / "workflows"
OUT.mkdir(exist_ok=True)

CRED = {
    "pg_monitor": {"postgres": {"id": "cred-pg-monitor", "name": "PG Monitor (monitor_n8n)"}},
    "telegram": {"telegramApi": {"id": "cred-telegram", "name": "Telegram Bot NutriAnimales"}},
    "webhook": {"httpHeaderAuth": {"id": "cred-webhook", "name": "Token Webhook Host"}},
}


def nid():
    return str(uuid.uuid4())


def node(name, ntype, version, params, pos, creds=None, **extra):
    n = {"parameters": params, "id": nid(), "name": name, "type": ntype,
         "typeVersion": version, "position": pos}
    if creds:
        n["credentials"] = creds
    n.update(extra)
    return n


def code(name, js, pos):
    return node(name, "n8n-nodes-base.code", 2, {"jsCode": js.strip()}, pos)


def telegram_send(name, pos):
    return node(name, "n8n-nodes-base.telegram", 1.2, {
        "chatId": "={{ $json.chat_id }}",
        "text": "={{ $json.texto }}",
        "additionalFields": {"appendAttribution": False},
    }, pos, CRED["telegram"])


def pg(name, query, pos, **extra):
    return node(name, "n8n-nodes-base.postgres", 2.5,
                {"operation": "executeQuery", "query": query, "options": {}},
                pos, CRED["pg_monitor"], **extra)


def link(conns, src, dst):
    conns.setdefault(src, {"main": [[]]})["main"][0].append({"node": dst, "type": "main", "index": 0})


def workflow(name, nodes, conns):
    return {
        "name": name, "nodes": nodes, "connections": conns, "active": False,
        "settings": {"executionOrder": "v1", "timezone": "America/Costa_Rica",
                     "saveDataSuccessExecution": "none", "saveDataErrorExecution": "all"},
        "pinData": {},
    }


def save(fname, wf):
    (OUT / fname).write_text(json.dumps(wf, ensure_ascii=False, indent=2), encoding="utf-8")
    print("escrito", OUT / fname, f"({len(wf['nodes'])} nodos)")


FILTRO = r"""
// Solo pasan filas con una alerta nueva (la BD ya deduplicó).
const out = [];
for (const item of $input.all()) {
  const j = item.json || {};
  if (j.texto && j.chat_id && j.chat_id !== '0') {
    out.push({ json: { chat_id: j.chat_id, codigo: j.codigo, texto: String(j.texto).slice(0, 4000) } });
  }
}
return out;
"""

# ---------------- 01: alertas de base de datos ----------------
ALERTAS = [
    ("R1", "Consulta lenta"), ("R2", "Saturación de conexiones"), ("R3", "Horario no laboral"),
    ("R4", "Autenticación fallida PG"), ("R5", "Cambio en postgresql.conf"),
    ("H2", "Hash pg_hba / postgresql.conf"), ("H3", "GRANT a agente_ia"),
    ("H4", "IP fuera de red Docker"), ("H5", "SSL off / MD5"),
    ("D1", "DELETE masivo"), ("D2", "Crecimiento anormal"), ("D3", "Backup obsoleto"),
    ("D4", "Duplicados"), ("D5", "Bloqueos / deadlock"), ("D6", "UPDATE masivo"),
    ("D7", "SELECT masivo en tabla sensible"),
]
nodes, conns = [], {}
trig = node("Cada minuto", "n8n-nodes-base.scheduleTrigger", 1.2,
            {"rule": {"interval": [{"field": "minutes", "minutesInterval": 1}]}}, [0, 760])
fil = code("Filtrar alertas nuevas", FILTRO, [700, 760])
tg = telegram_send("Enviar a Telegram", [940, 760])
nodes += [trig, fil, tg]
for i, (cod, desc) in enumerate(ALERTAS):
    n = pg(f"{cod} · {desc}", f"SELECT * FROM monitor.ejecutar_chequeo('{cod}');",
           [340, i * 100], onError="continueRegularOutput")
    nodes.append(n)
    link(conns, trig["name"], n["name"])
    link(conns, n["name"], fil["name"])
link(conns, fil["name"], tg["name"])
save("01_alertas_bd.json", workflow("NutriAnimales · 16 alertas de BD (R/H/D)", nodes, conns))

# ---------------- 02: alertas del host por webhook ----------------
VALIDAR = r"""
// Valida el payload del monitor del host y lo codifica en base64
// para pasarlo a PostgreSQL sin concatenar texto libre en el SQL.
const out = [];
for (const item of $input.all()) {
  const b = item.json.body || {};
  if (!['H1', 'R4'].includes(b.codigo)) continue;
  const limpio = {
    codigo: b.codigo,
    severidad: b.severidad === 'ADVERTENCIA' ? 'ADVERTENCIA' : 'CRÍTICA',
    titulo: String(b.titulo || '').slice(0, 150),
    detalle: String(b.detalle || '').slice(0, 3000),
    clave: String(b.clave || b.codigo).slice(0, 150),
  };
  out.push({ json: { b64: Buffer.from(JSON.stringify(limpio), 'utf8').toString('base64') } });
}
return out;
"""
nodes, conns = [], {}
wh = node("Webhook monitor del host", "n8n-nodes-base.webhook", 2,
          {"httpMethod": "POST", "path": "alertas-host", "authentication": "headerAuth",
           "responseMode": "onReceived", "options": {}},
          [0, 300], CRED["webhook"], webhookId=nid())
val = code("Validar payload", VALIDAR, [240, 300])
reg = pg("Registrar alerta (dedup)",
         "=SELECT * FROM monitor.registrar_alerta_externa(convert_from(decode('{{ $json.b64 }}', 'base64'), 'UTF8')::jsonb);",
         [480, 300])
fil = code("Filtrar alertas nuevas", FILTRO, [720, 300])
tg = telegram_send("Enviar a Telegram", [960, 300])
nodes += [wh, val, reg, fil, tg]
for a, b in [(wh, val), (val, reg), (reg, fil), (fil, tg)]:
    link(conns, a["name"], b["name"])
save("02_alertas_host.json", workflow("NutriAnimales · Alertas del host (H1 UFW, R4 SSH)", nodes, conns))
