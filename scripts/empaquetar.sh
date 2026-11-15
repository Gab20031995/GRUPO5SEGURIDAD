#!/usr/bin/env bash
# =====================================================================
#  empaquetar.sh — Genera el ZIP de entrega a partir de lo versionado en
#  git (HEAD). Así nunca entran .env, data/, backups/, certificados,
#  monitor_host.env ni evidencias/ (todos están en .gitignore).
#
#  Uso: ./scripts/empaquetar.sh   ->  ../entrega/nutrianimales-seguridad_<fecha>.zip
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "⚠ Hay cambios sin commit; el ZIP se arma desde el último commit (HEAD)."
  git status --short --untracked-files=no
fi

DEST="../entrega"; mkdir -p "$DEST"
ZIP="$DEST/nutrianimales-seguridad_$(date +%Y%m%d).zip"
git archive --format=zip --prefix=nutrianimales-seguridad/ -o "$ZIP" HEAD

# Verificación: ningún archivo prohibido ni valor real de .env dentro del ZIP
python3 -I - "$ZIP" <<'PY' || { rm -f "$ZIP"; exit 1; }
import re, sys, zipfile, pathlib
z = zipfile.ZipFile(sys.argv[1])
prohibidos = re.compile(r'(^|/)\.env$|/data/|/backups/|\.key$|\.pem$|nginx/certs|monitor_host\.env$|\.swp$|evidencias/')
malos = [n for n in z.namelist() if prohibidos.search(n)]
secretos = {}
env = pathlib.Path('.env')
if env.exists():
    for l in env.read_text().splitlines():
        k, _, v = l.partition('=')
        if re.search(r'PASSWORD|TOKEN|KEY|SECRET', k) and not k.startswith('#') and len(v.strip()) >= 8:
            secretos[k.strip()] = v.strip().encode()
fugas = {k for n in z.namelist() if not n.endswith('/') for k, v in secretos.items() if v in z.read(n)}
if malos or fugas:
    print('✘ Archivos prohibidos:', malos); print('✘ Secretos encontrados:', sorted(fugas)); sys.exit(1)
print(f'{len([n for n in z.namelist() if not n.endswith("/")])} archivos revisados, sin secretos')
PY
echo "✔ $ZIP  ($(du -h "$ZIP" | cut -f1))"
