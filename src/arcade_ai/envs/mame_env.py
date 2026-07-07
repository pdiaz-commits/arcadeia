"""Stub para integración MAME (MAMEToolkit / Lua + TCP)."""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_LOCAL_MAME = _PROJECT_ROOT / "bin" / "mame"
_VENDOR_MAME = _PROJECT_ROOT / "vendor" / "mame" / "mame0288-arm64" / "mame"


@dataclass
class MameConfig:
    game_id: str
    roms_path: Path
    mame_binary: str = "mame"


class MameNotAvailableError(RuntimeError):
    pass


def resolve_mame_binary() -> str | None:
    if _LOCAL_MAME.is_file():
        return str(_LOCAL_MAME)
    if _VENDOR_MAME.is_file():
        return str(_VENDOR_MAME)
    return shutil.which("mame")


def mame_version() -> str | None:
    binary = resolve_mame_binary()
    if not binary:
        return None
    env = os.environ.copy()
    frameworks = _PROJECT_ROOT / "vendor" / "Frameworks"
    if frameworks.is_dir():
        env["DYLD_FRAMEWORK_PATH"] = str(frameworks) + (
            f":{env['DYLD_FRAMEWORK_PATH']}" if env.get("DYLD_FRAMEWORK_PATH") else ""
        )
    try:
        out = subprocess.run(
            [binary, "-version"],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        if out.returncode == 0:
            return out.stdout.strip().splitlines()[0]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def mame_status() -> dict:
    binary = resolve_mame_binary()
    roms = _PROJECT_ROOT / "roms"
    version = mame_version()
    installed = binary is not None and version is not None
    return {
        "mame_installed": installed,
        "mame_path": binary,
        "mame_version": version,
        "roms_dir": str(roms),
        "roms_dir_exists": roms.is_dir(),
        "hint": (
            "Ejecuta: ./scripts/install_mame.sh"
            if not installed
            else "Coloca ROMs legales en arcade-ai/roms/"
        ),
    }
