#!/usr/bin/env python3
"""
Genera 03_bot_telegram.json: el bot de consultas para la gerencia.

Flujo:
  Telegram Trigger
   -> Normalizar e inspeccionar entrada (RBAC por chat_id + validación de entrada)
   -> IF autorizado y entrada válida
        SÍ  -> Groq (genera UNA consulta SELECT sobre el esquema reportes.*)
            -> Validar que la respuesta sea solo-lectura
            -> Postgres como agente_ia (usuario de solo lectura, read-only tx)
            -> Formatear resultado -> Telegram
        NO  -> Registrar intento en auditoría -> Responder rechazo -> Telegram

Defensa en profundidad del escenario A2 (inyección):
  1. El bot NO ejecuta lo que escribe la persona; se lo pasa a la IA como texto.
  2. La IA recibe la instrucción de producir solo un SELECT sobre reportes.*
  3. Se valida que lo devuelto por la IA empiece por SELECT y no traiga
     separadores de sentencia ni verbos de escritura.
  4. La conexión usa agente_ia: solo SELECT, transacción de solo lectura y
     statement_timeout de 5 s a nivel de rol. Aunque algo se escapara de los
     filtros anteriores, la base de datos rechaza cualquier escritura.
"""
import json
import uuid
from pathlib import Path

OUT = Path(__file__).parent / "workflows"
OUT.mkdir(exist_ok=True)


def nid():
    return str(uuid.uuid4())


def n(name, ntype, ver, params, pos, creds=None, **extra):
    d = {"parameters": params, "id": nid(), "name": name, "type": ntype,
         "typeVersion": ver, "position": pos}
    if creds:
        d["credentials"] = creds
    d.update(extra)
    return d


def link(conns, src, dst, out=0):
    arr = conns.setdefault(src, {"main": []})["main"]
    while len(arr) <= out:
        arr.append([])
    arr[out].append({"node": dst, "type": "main", "index": 0})


# ---- Inspección de entrada: RBAC + validación de que la pregunta es admisible
INSPECCIONAR = r"""
// 1) Identifica al usuario de Telegram y recupera su rol desde la BD (nodo previo).
// 2) Marca como no admisible cualquier entrada que intente colar sintaxis SQL,
//    en lugar de ejecutarla. Lo que se bloquea queda registrado en auditoría.
const roles = {};
for (const it of ($items("Rol del usuario") || [])) {
  const r = it.json || {};
  if (r.chat_id) roles[String(r.chat_id)] = r.rol;
}
const indicadores = [
  /;/, /--/, /\/\*/, /\bunion\b/i,
  /\b(drop|delete|truncate|alter|insert|update|grant|revoke|create|copy|call|merge)\b/i,
  /'\s*or\s+/i,
];
const out = [];
for (const item of $input.all()) {
  const m = item.json.message || {};
  const chat_id = Number(m.chat && m.chat.id);
  if (!Number.isInteger(chat_id)) continue;
  const pregunta = String(m.text || '').trim().slice(0, 300);
  const usuario = (m.from && (m.from.username || m.from.first_name)) || 'desconocido';
  const rol = roles[String(chat_id)] || null;
  const admisible = pregunta.length > 0 && !indicadores.some((re) => re.test(pregunta));
  const payload = { chat_id: String(chat_id), usuario, pregunta, rol,
                    motivo: !rol ? 'usuario no autorizado' : (!admisible ? 'entrada con sintaxis SQL' : null) };
  out.push({ json: { ...payload, ok: !!rol && admisible,
                     b64: Buffer.from(JSON.stringify(payload), 'utf8').toString('base64') } });
}
return out;
"""

# ---- Prompt de sistema para Groq (texto -> SELECT)
SYS_PROMPT = (
    "Eres el asistente de reportes de NutriAnimales S.A. Conviertes la pregunta "
    "del gerente en UNA sola consulta SQL de PostgreSQL. Reglas estrictas: "
    "1) Solo SELECT. 2) Usa unicamente las vistas del esquema reportes: "
    "reportes.v_ventas_mensuales(mes,linea,num_ventas,sacos,monto_total), "
    "reportes.v_top_clientes(cliente_id,nombre,tipo,segmento,num_compras,monto_total), "
    "reportes.v_produccion_por_planta(planta,mes,estado,lotes,sacos), "
    "reportes.v_inventario_critico(nombre,categoria,stock_actual,stock_minimo,proveedor,bajo_minimo), "
    "reportes.v_calidad_por_lote(lote,producto,parametro,valor_obtenido,valor_esperado,aprobado), "
    "reportes.v_gastos_mensuales(mes,categoria,monto_total,registros). "
    "3) Agrega siempre LIMIT 50 si no hay agregacion. 4) No uses punto y coma ni comentarios. "
    "5) Responde solo con el SQL, sin explicaciones ni formato Markdown."
)

PREP_GROQ = r"""
const r = $input.first().json;
return [{ json: {
  chat_id: r.chat_id, usuario: r.usuario, rol: r.rol, pregunta: r.pregunta,
  body: {
    model: 'llama-3.3-70b-versatile',
    temperature: 0,
    max_tokens: 400,
    messages: [
      { role: 'system', content: $json.sys },
      { role: 'user', content: r.pregunta },
    ],
  },
} }];
""".replace("$json.sys", json.dumps(SYS_PROMPT))

# ---- Validación de lo que devolvió la IA (debe ser solo-lectura)
VALIDAR_SQL = r"""
const prev = $items("Preparar prompt")[0].json;
const resp = $input.first().json;
let sql = '';
try { sql = resp.choices[0].message.content.trim(); } catch (e) { sql = ''; }
sql = sql.replace(/^```sql/i, '').replace(/```$/,'').trim();
// Debe ser un unico SELECT, sin separadores ni verbos de escritura.
const unaSentencia = !sql.includes(';');
const empiezaSelect = /^select\b/i.test(sql) || /^with\b/i.test(sql);
const sinEscritura = !/\b(insert|update|delete|drop|alter|truncate|grant|revoke|create|copy|call|merge)\b/i.test(sql);
const soloReportes = !/\bfrom\b\s+(?!reportes\.)/i.test(sql) ? true : /from\s+reportes\./i.test(sql);
const valido = sql.length > 0 && unaSentencia && empiezaSelect && sinEscritura;
return [{ json: {
  chat_id: prev.chat_id, usuario: prev.usuario, pregunta: prev.pregunta,
  sql, valido,
  b64: Buffer.from(sql, 'utf8').toString('base64'),
} }];
"""

FORMATEAR = r"""
const info = $items("Validar SQL")[0].json;
const filas = $input.all().map(i => i.json);
let cuerpo;
if (!filas.length) {
  cuerpo = 'Sin resultados para la consulta.';
} else {
  const cols = Object.keys(filas[0]);
  cuerpo = filas.slice(0, 20).map(f => cols.map(c => `${c}: ${f[c]}`).join(' · ')).join('\n');
  if (filas.length > 20) cuerpo += `\n… (${filas.length - 20} filas más)`;
}
return [{ json: { chat_id: info.chat_id,
  texto: `📊 NutriAnimales S.A.\nConsulta: ${info.pregunta}\n\n${cuerpo}` } }];
"""

RECHAZO = r"""
const r = $input.first().json;
return [{ json: { chat_id: r.chat_id,
  texto: `⛔ No se pudo atender la solicitud.\nMotivo: ${r.motivo || 'la consulta generada no es de solo lectura'}.\nEl bot solo responde reportes agregados a usuarios autorizados.\nEl intento quedó registrado.` } }];
"""

CRED_TG = {"telegramApi": {"id": "cred-telegram", "name": "Telegram Bot NutriAnimales"}}
CRED_MON = {"postgres": {"id": "cred-pg-monitor", "name": "PG Monitor (monitor_n8n)"}}
CRED_AG = {"postgres": {"id": "cred-pg-agente", "name": "PG Agente IA (agente_ia)"}}
CRED_GROQ = {"httpHeaderAuth": {"id": "cred-groq", "name": "Groq API"}}

nodes, conns = [], {}

trig = n("Telegram Trigger", "n8n-nodes-base.telegramTrigger", 1.2,
         {"updates": ["message"], "additionalFields": {}}, [0, 400], CRED_TG, webhookId=nid())

rol = n("Rol del usuario", "n8n-nodes-base.postgres", 2.5,
        {"operation": "executeQuery",
         "query": "=SELECT '{{ $json.message.chat.id }}'::text AS chat_id, monitor.rol_usuario_bot({{ $json.message.chat.id }}) AS rol;",
         "options": {}}, [240, 400], CRED_MON)

insp = n("Inspeccionar entrada", "n8n-nodes-base.code", 2, {"jsCode": INSPECCIONAR.strip()}, [480, 400])

gate = n("¿Autorizado y válido?", "n8n-nodes-base.if", 2,
         {"conditions": {"options": {"caseSensitive": True, "typeValidation": "loose"},
                         "combinator": "and",
                         "conditions": [{"leftValue": "={{ $json.ok }}", "rightValue": True,
                                         "operator": {"type": "boolean", "operation": "true", "singleValue": True}}]}},
         [720, 400])

prep = n("Preparar prompt", "n8n-nodes-base.code", 2, {"jsCode": PREP_GROQ.strip()}, [960, 300])

groq = n("Groq · generar SELECT", "n8n-nodes-base.httpRequest", 4.2,
         {"method": "POST", "url": "https://api.groq.com/openai/v1/chat/completions",
          "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
          "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify($json.body) }}",
          "options": {}}, [1180, 300], CRED_GROQ)

valsql = n("Validar SQL", "n8n-nodes-base.code", 2, {"jsCode": VALIDAR_SQL.strip()}, [1400, 300])

gate2 = n("¿SELECT válido?", "n8n-nodes-base.if", 2,
          {"conditions": {"options": {"caseSensitive": True, "typeValidation": "loose"},
                          "combinator": "and",
                          "conditions": [{"leftValue": "={{ $json.valido }}", "rightValue": True,
                                          "operator": {"type": "boolean", "operation": "true", "singleValue": True}}]}},
          [1620, 300])

ejec = n("Ejecutar como agente_ia", "n8n-nodes-base.postgres", 2.5,
         {"operation": "executeQuery",
          "query": "=SELECT * FROM (\n  {{ Buffer.from($json.b64, 'base64').toString('utf8') }}\n) AS consulta_bot LIMIT 50;",
          "options": {}}, [1840, 220], CRED_AG)

fmt = n("Formatear resultado", "n8n-nodes-base.code", 2, {"jsCode": FORMATEAR.strip()}, [2060, 220])

# Registrar intentos rechazados (no autorizado / entrada inválida / SQL inválido)
reg = n("Registrar intento", "n8n-nodes-base.postgres", 2.5,
        {"operation": "executeQuery",
         "query": "=SELECT monitor.registrar_bloqueo_bot(convert_from(decode('{{ $json.b64 }}', 'base64'), 'UTF8')::jsonb) AS id;",
         "options": {}}, [960, 560], CRED_MON, onError="continueRegularOutput")

rech = n("Preparar rechazo", "n8n-nodes-base.code", 2, {"jsCode": RECHAZO.strip()}, [1180, 560])

tg_ok = n("Responder resultado", "n8n-nodes-base.telegram", 1.2,
          {"chatId": "={{ $json.chat_id }}", "text": "={{ $json.texto }}",
           "additionalFields": {"appendAttribution": False}}, [2280, 220], CRED_TG)

tg_no = n("Responder rechazo", "n8n-nodes-base.telegram", 1.2,
          {"chatId": "={{ $json.chat_id }}", "text": "={{ $json.texto }}",
           "additionalFields": {"appendAttribution": False}}, [1400, 560], CRED_TG)

nodes += [trig, rol, insp, gate, prep, groq, valsql, gate2, ejec, fmt, reg, rech, tg_ok, tg_no]

link(conns, trig["name"], rol["name"])
link(conns, rol["name"], insp["name"])
link(conns, insp["name"], gate["name"])
link(conns, gate["name"], prep["name"], 0)      # true
link(conns, gate["name"], reg["name"], 1)       # false -> auditoría
link(conns, prep["name"], groq["name"])
link(conns, groq["name"], valsql["name"])
link(conns, valsql["name"], gate2["name"])
link(conns, gate2["name"], ejec["name"], 0)     # true
link(conns, gate2["name"], reg["name"], 1)      # false -> auditoría
link(conns, ejec["name"], fmt["name"])
link(conns, fmt["name"], tg_ok["name"])
link(conns, reg["name"], rech["name"])
link(conns, rech["name"], tg_no["name"])

wf = {"name": "NutriAnimales · Bot de consultas (gerencia)", "nodes": nodes,
      "connections": conns, "active": False,
      "settings": {"executionOrder": "v1", "timezone": "America/Costa_Rica",
                   "saveDataSuccessExecution": "none", "saveDataErrorExecution": "all"},
      "pinData": {}}
(OUT / "03_bot_telegram.json").write_text(json.dumps(wf, ensure_ascii=False, indent=2), encoding="utf-8")
print("escrito", OUT / "03_bot_telegram.json", f"({len(nodes)} nodos)")
