#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Arcade AI — setup local ==="

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 no encontrado"
  exit 1
fi

python3 -m venv .venv
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt

echo ""
echo "MAME:"
if command -v mame &>/dev/null; then
  echo "  ✅ $(mame -version 2>/dev/null | head -1 || mame --version 2>/dev/null | head -1)"
else
  echo "  ⏳ No instalado. Para ROMs arcade cabinet:"
  echo "     brew install mame"
fi

echo ""
echo "Demo rápida (sin ventana):"
python scripts/play.py --game breakout --agent random --episodes 2

echo ""
echo "Dashboard:  uvicorn scripts.dashboard:app --reload --port 8765"
echo "Con gráficos: python scripts/play.py --game breakout --agent heuristic --render"
