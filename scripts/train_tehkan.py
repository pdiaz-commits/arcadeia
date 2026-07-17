#!/usr/bin/env python3
"""Entrena un agente PPO de Stable Baselines 3 sobre Tehkan World Cup.

Uso:
    source .venv/bin/activate
    ./scripts/train_tehkan.py --total-timesteps 200000 --n-envs 2

Requisitos:
    - ROM `tehkanwc.zip` en ``roms/``.
    - MAME 0.288 instalado (vendor o brew).
    - ``pip install "stable-baselines3[extra]"`` (ver requirements.txt).

Notas:
    - El primer entrenamiento es LENTO por overhead de lanzar MAME por
      sub-proceso. Empieza con ``--n-envs 1`` para validar el flujo y
      luego sube a 2-3 para entrenos largos.
    - TensorBoard: ``tensorboard --logdir=models/tehkan_ppo/tb``.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import numpy as np  # noqa: E402

from arcade_ai.envs.tehkan_env import TehkanEnv  # noqa: E402


def make_env_fn(env_id: int):
    """Devuelve un thunk estable para SubprocVecEnv / DummyVecEnv."""
    def _thunk() -> TehkanEnv:
        return TehkanEnv(env_id=env_id)
    return _thunk


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Train PPO on Tehkan World Cup via MAME+lua bridge."
    )
    parser.add_argument("--total-timesteps", type=int, default=100_000)
    parser.add_argument("--n-envs", type=int, default=1,
                        help="Subprocesos MAME simultaneos (1-3 recomendado).")
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--n-steps", type=int, default=512)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--n-epochs", type=int, default=10)
    parser.add_argument("--gamma", type=float, default=0.99)
    parser.add_argument("--ent-coef", type=float, default=0.01)
    parser.add_argument("--out-dir", default="models/tehkan_ppo")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--no-tensorboard", action="store_true")
    args = parser.parse_args()

    # Importaciones perezosas — solo fallan si SB3 no instalado.
    from stable_baselines3 import PPO
    from stable_baselines3.common.vec_env import SubprocVecEnv, DummyVecEnv
    from stable_baselines3.common.callbacks import CheckpointCallback

    if args.n_envs > 1:
        # SubprocVecEnv hace fork(): TehkanEnv se lanza al hacer reset().
        vec = SubprocVecEnv(
            [make_env_fn(i) for i in range(args.n_envs)],
            start_method="fork",
        )
    else:
        vec = DummyVecEnv([make_env_fn(0)])

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    tb_dir = None if args.no_tensorboard else str(out_dir / "tb")
    if tb_dir:
        os.makedirs(tb_dir, exist_ok=True)

    model = PPO(
        "MlpPolicy",
        vec,
        learning_rate=args.learning_rate,
        n_steps=args.n_steps,
        batch_size=args.batch_size,
        n_epochs=args.n_epochs,
        gamma=args.gamma,
        ent_coef=args.ent_coef,
        verbose=1,
        seed=args.seed,
        tensorboard_log=tb_dir,
    )

    cb = CheckpointCallback(
        save_freq=max(args.n_steps * 5, 1_000),
        save_path=str(out_dir / "ckpt"),
        name_prefix="ppo_tehkan",
    )

    print(f"Entrenando PPO {args.total_timesteps} pasos, {args.n_envs} envs, "
          f"lr={args.learning_rate}, out={out_dir}")
    try:
        model.learn(
            total_timesteps=args.total_timesteps,
            callback=cb,
            progress_bar=False,
        )
    except KeyboardInterrupt:
        print("\nEntrenamiento interrumpido. Guardando checkpoint...")
    finally:
        model.save(str(out_dir / "ppo_tehkan_final.zip"))
        vec.close()
        print(f"Modelo guardado en {out_dir / 'ppo_tehkan_final.zip'}")


if __name__ == "__main__":
    main()
