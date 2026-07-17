#!/usr/bin/env python3
"""Agente Tehkan World Cup: captura ventana MAME + trackball (ratón) + teclado.

Estrategia según prompt arcade: esprint diagonal con balón, cortar sin balón,
chute = movimiento rápido + Ctrl. Moneda=5, Start=1.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import pyautogui
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SNAP_DIR = ROOT / "snap" / "agent"
pyautogui.FAILSAFE = False
pyautogui.PAUSE = 0


@dataclass
class GameState:
    phase: str  # title | play | unknown
    ball: tuple[int, int] | None
    player: tuple[int, int] | None
    score_top: str = ""


def mame_window_bounds() -> tuple[int, int, int, int] | None:
    """Devuelve (left, top, width, height) de la ventana MAME en macOS."""
    script = r'''
    tell application "System Events"
        repeat with p in (every process whose background only is false)
            if name of p contains "mame" then
                repeat with w in (every window of p)
                    set {x, y} to position of w
                    set {wd, ht} to size of w
                    return (x as text) & "," & (y as text) & "," & (wd as text) & "," & (ht as text)
                end repeat
            end if
        end repeat
    end tell
    return ""
    '''
    try:
        out = subprocess.check_output(["osascript", "-e", script], text=True).strip()
    except subprocess.CalledProcessError:
        return None
    if not out or "," not in out:
        return None
    parts = [int(float(v)) for v in out.split(",")[:4]]
    if len(parts) < 4:
        return None
    return parts[0], parts[1], parts[2], parts[3]


def grab_mame_frame() -> Image.Image | None:
    bounds = mame_window_bounds()
    if not bounds:
        return None
    left, top, w, h = bounds
    if w < 200 or h < 200:
        return None
    return pyautogui.screenshot(region=(left, top, w, h))


def focus_mame() -> bool:
    script = '''
    tell application "System Events"
        repeat with p in (every process whose background only is false)
            if name of p contains "mame" then
                set frontmost of p to true
                return "ok"
            end if
        end repeat
    end tell
    '''
    try:
        return subprocess.check_output(["osascript", "-e", script], text=True).strip() == "ok"
    except subprocess.CalledProcessError:
        return False


def find_bright_blob(img: Image.Image, y_min: int, y_max: int, min_v: int = 200) -> tuple[int, int] | None:
    """Localiza el balón (píxel claro) en una franja vertical del campo."""
    rgb = img.convert("RGB")
    w, h = rgb.size
    y0 = max(0, int(h * y_min))
    y1 = min(h, int(h * y_max))
    best = None
    best_score = 0
    step = 2
    for y in range(y0, y1, step):
        for x in range(0, w, step):
            r, g, b = rgb.getpixel((x, y))
            v = max(r, g, b)
            if v >= min_v and r > 160 and g > 160 and b > 140:
                score = v + (255 - abs(r - g))
                if score > best_score:
                    best_score = score
                    best = (x, y)
    return best


def find_player_near_ball(img: Image.Image, ball: tuple[int, int]) -> tuple[int, int]:
    """Jugador activo ≈ mancha de color cerca del balón."""
    rgb = img.convert("RGB")
    w, h = rgb.size
    bx, by = ball
    best = ball
    best_d = 9999
    for dy in range(-40, 41, 3):
        for dx in range(-40, 41, 3):
            x = bx + dx
            y = by + dy
            if x < 0 or y < 0 or x >= w or y >= h:
                continue
            r, g, b = rgb.getpixel((x, y))
            if r < 40 and g < 40 and b < 40:
                continue
            if r > 220 and g > 220 and b > 200:
                continue
            d = abs(dx) + abs(dy)
            if d < best_d and (r > 80 or g > 80 or b > 80):
                best_d = d
                best = (x, y)
    return best


def parse_state(img: Image.Image) -> GameState:
    w, h = img.size
    top = img.crop((0, 0, w, int(h * 0.12)))
    top_rgb = top.convert("RGB")
    green_px = sum(
        1
        for y in range(top.height)
        for x in range(top.width)
        if top_rgb.getpixel((x, y))[1] > top_rgb.getpixel((x, y))[0]
    )
    if green_px < top.width * top.height * 0.05:
        return GameState(phase="title", ball=None, player=None)

    ball = find_bright_blob(img, 0.08, 0.95, min_v=210)
    if not ball:
        return GameState(phase="unknown", ball=None, player=None)
    player = find_player_near_ball(img, ball)
    return GameState(phase="play", ball=ball, player=player)


def trackball_drag(dx: int, dy: int, duration: float = 0.06) -> None:
    """Movimiento trackball: arrastre relativo rápido = esprint."""
    if dx == 0 and dy == 0:
        return
    pyautogui.moveRel(dx, dy, duration=duration, tween=pyautogui.linear)


def kick_with_drag(dx: int, dy: int) -> None:
    trackball_drag(dx, dy, duration=0.04)
    pyautogui.keyDown("ctrl")
    time.sleep(0.03)
    pyautogui.keyUp("ctrl")


def boot_if_title(state: GameState) -> None:
    if state.phase != "title":
        return
    pyautogui.press("5")
    time.sleep(0.15)
    pyautogui.press("1")
    time.sleep(0.1)


def act(state: GameState, img: Image.Image) -> None:
    if state.phase != "play" or not state.ball or not state.player:
        return

    w, h = img.size
    bx, by = state.ball
    px, py = state.player
    has_ball = abs(bx - px) + abs(by - py) < 28
    attack_up = py > h * 0.35  # portería rival arriba en pantalla

    if has_ball:
        band = -1 if px < w * 0.45 else 1
        if attack_up:
            if py < h * 0.28:
                kick_with_drag(int(band * 55), -70)
            else:
                trackball_drag(int(band * 42), -58, duration=0.05)
                trackball_drag(int(band * 38), -52, duration=0.05)
        else:
            trackball_drag(int(band * 40), -55, duration=0.05)
            trackball_drag(int(band * 36), -50, duration=0.05)
    else:
        dx = int((bx - px) * 0.9)
        dy = int((by - py) * 0.9)
        dy = min(dy, -40)
        trackball_drag(dx, dy, duration=0.05)
        if abs(bx - px) + abs(by - py) < 22:
            kick_with_drag(dx // 2, dy // 2)


def main() -> None:
    parser = argparse.ArgumentParser(description="Agente Tehkan (captura + trackball)")
    parser.add_argument("--steps", type=int, default=600, help="Iteraciones del bucle")
    parser.add_argument("--interval", type=float, default=0.12, help="Segundos entre frames")
    parser.add_argument("--snap-every", type=int, default=30, help="Guardar captura cada N pasos")
    args = parser.parse_args()

    SNAP_DIR.mkdir(parents=True, exist_ok=True)
    if not focus_mame():
        print("No encuentro ventana MAME. Lanza: ./run.sh tehkan_world_cup heuristic --render")
        print("O sin Lua: mame tehkanwc -rompath roms -window -mouse")
        sys.exit(1)

    print("Agente Tehkan — captura + trackball. Ctrl+C para parar.")
    for step in range(args.steps):
        img = grab_mame_frame()
        if img is None:
            time.sleep(0.2)
            continue
        state = parse_state(img)
        boot_if_title(state)
        act(state, img)
        if args.snap_every and step % args.snap_every == 0:
            img.save(SNAP_DIR / f"frame_{step:05d}.png")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
