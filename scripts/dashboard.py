#!/usr/bin/env python3
"""Dashboard web mínimo — estado del proyecto y demo de agentes."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from fastapi import FastAPI
from fastapi.responses import HTMLResponse

from arcade_ai import __version__
from arcade_ai.envs.ale_env import list_ale_games, load_games_config
from arcade_ai.envs.mame_env import mame_status

app = FastAPI(title="Arcade AI", version=__version__)


@app.get("/", response_class=HTMLResponse)
def home():
    cfg = load_games_config()
    ale = list_ale_games()
    mame = cfg.get("mame_games", {})
    ms = mame_status()
    ale_rows = "".join(
        f"<tr><td>{k}</td><td>{v['year']}</td><td>{v['env_id']}</td>"
        f"<td>{v['description']}</td></tr>"
        for k, v in ale.items()
    )
    mame_rows = "".join(
        f"<tr><td>{k}</td><td>{v['year']}</td><td><code>{v['game_id']}</code></td>"
        f"<td>{v['description']}</td></tr>"
        for k, v in mame.items()
    )
    mame_badge = (
        f"✅ {ms['mame_version']}"
        if ms["mame_installed"]
        else "⏳ pendiente (./scripts/install_mame.sh)"
    )
    return f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8"/>
  <title>Arcade AI</title>
  <style>
    body {{ font-family: system-ui, sans-serif; max-width: 900px; margin: 2rem auto; padding: 0 1rem; }}
    h1 {{ color: #1a1a2e; }}
    table {{ border-collapse: collapse; width: 100%; margin: 1rem 0; }}
    th, td {{ border: 1px solid #ddd; padding: 0.5rem; text-align: left; }}
    th {{ background: #16213e; color: #fff; }}
    code {{ background: #f4f4f4; padding: 0.15rem 0.4rem; border-radius: 4px; }}
    .card {{ background: #f8f9fa; border-radius: 8px; padding: 1rem; margin: 1rem 0; }}
    a {{ color: #0f3460; }}
  </style>
</head>
<body>
  <h1>🕹️ Arcade AI <small>v{__version__}</small></h1>
  <p>TFM-style: juegos arcade + agentes con distintos niveles de IA (random → heurístico → RL).</p>
  <p>Inspirado en <a href="https://machinelearning.pablodiaz.eu">machinelearning.pablodiaz.eu</a> (Columns AI).</p>

  <div class="card">
    <strong>MAME:</strong> {mame_badge}<br/>
    <strong>ROMs:</strong> <code>{ms['roms_dir']}</code>
  </div>

  <h2>Juegos ALE (activos en local)</h2>
  <table>
    <tr><th>Clave</th><th>Año</th><th>Env ID</th><th>Descripción</th></tr>
    {ale_rows}
  </table>

  <h2>Juegos MAME (próximo paso)</h2>
  <table>
    <tr><th>Clave</th><th>Año</th><th>Game ID</th><th>Descripción</th></tr>
    {mame_rows}
  </table>

  <h2>Comandos</h2>
  <pre>
cd arcade-ai
source .venv/bin/activate
python scripts/play.py --game breakout --agent heuristic --episodes 3
python scripts/play.py --game breakout --agent random --render
uvicorn scripts.dashboard:app --reload --port 8765
  </pre>
</body>
</html>"""


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8765)
