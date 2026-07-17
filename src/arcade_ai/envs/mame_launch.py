"""Helpers para lanzar MAME con plugins oficiales (autofire, hiscore, etc.)."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_CFG_DIR = _PROJECT_ROOT / "cfg"
_VENDOR_PLUGINS = _PROJECT_ROOT / "vendor" / "mame" / "mame0288-arm64" / "plugins"

# Perfiles — https://docs.mamedev.org/plugins/index.html
PLUGIN_PROFILES: dict[str, list[str]] = {
    "ai": ["hiscore"],
    "manual": ["hiscore", "autofire", "inputmacro"],
    "teach": ["hiscore", "console"],
    "debug": ["hiscore", "console", "cheat", "cheatfind"],
}


def resolve_plugins_dir() -> Path | None:
    if _VENDOR_PLUGINS.is_dir():
        return _VENDOR_PLUGINS
    return None


def mame_env() -> dict[str, str]:
    env = os.environ.copy()
    frameworks = _PROJECT_ROOT / "vendor" / "Frameworks"
    if frameworks.is_dir():
        env["DYLD_FRAMEWORK_PATH"] = str(frameworks) + (
            f":{env['DYLD_FRAMEWORK_PATH']}" if env.get("DYLD_FRAMEWORK_PATH") else ""
        )
    return env


def _flag_value(cmd: list[str], flag: str) -> str | None:
    try:
        idx = cmd.index(flag)
        return cmd[idx + 1]
    except (ValueError, IndexError):
        return None


def plugin_launch_args(
    profile: str = "ai",
    *,
    extra_plugins: Iterable[str] | None = None,
    game_plugins: Iterable[str] | None = None,
) -> list[str]:
    plugins_dir = resolve_plugins_dir()
    plugins = list(PLUGIN_PROFILES.get(profile, PLUGIN_PROFILES["ai"]))
    for source in (game_plugins, extra_plugins):
        if source:
            for name in source:
                if name not in plugins:
                    plugins.append(name)

    args: list[str] = []
    if plugins_dir:
        args.extend(["-pluginspath", str(plugins_dir)])
    args.extend(["-homepath", str(_PROJECT_ROOT)])
    if _CFG_DIR.is_dir():
        args.extend(["-inipath", f"{_CFG_DIR};."])
        args.extend(["-cfg_directory", str(_CFG_DIR)])
    if plugins and plugins_dir:
        args.extend(["-plugin", ",".join(plugins)])
    return args


def extend_mame_cmd(cmd: list[str], profile: str = "ai", **kwargs) -> list[str]:
    """Añade flags de plugin sin pisar opciones ya presentes en cmd."""
    extra = plugin_launch_args(profile, **kwargs)
    skip: set[str] = set()
    for flag in ("-cfg_directory", "-inipath", "-homepath", "-pluginspath", "-plugin"):
        if flag in cmd:
            skip.add(flag)
            val = _flag_value(cmd, flag)
            if val:
                skip.add(val)
    filtered: list[str] = []
    i = 0
    while i < len(extra):
        token = extra[i]
        if token in skip:
            i += 2 if i + 1 < len(extra) else 1
            continue
        filtered.append(token)
        i += 1
    return cmd + filtered
