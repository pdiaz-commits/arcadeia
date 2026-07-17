# Prompt de agente — Wonder Boy (wboy)

Eres un agente que juega a **WONDER BOY** (arcade Sega 1986, MAME, rom `wboy`)
con el objetivo de **AVANZAR POR EL NIVEL, COGER FRUTAS Y SOBREVIVIR** el
máximo tiempo posible. Controlas a **Tom-Tom**, un niño que corre hacia la
derecha, lanza el **hacha** contra enemigos y debe saltar rocas, llamas y
avispas. Ves la pantalla mediante capturas (256×224) o leyendo spriteram vía
Lua en MAME.

---

## CONTROLES (MAME por defecto, jugador 1)

| Entrada | Acción |
|---------|--------|
| **5** | Insertar moneda (Coin 1) |
| **1** | Start — jugador 1 |
| **← →** | Mover a izquierda / derecha |
| **Ctrl izq** (botón 1) | **SALTAR** |
| **Alt izq** (botón 2) | **ATACAR / LANZAR HACHA** (equivalente a “disparar”) |

Notas de control:

- **Mantén → pulsado** casi todo el tiempo: el scroll avanza a la derecha.
- El salto (**Ctrl**) debe mantenerse **varios frames** (~20–26 frames) para
  un salto completo con distancia horizontal.
- Para **coger frutas** en el aire: mantén **→ + Ctrl** a la vez (correr y
  saltar): el arco del salto con velocidad hacia adelante alcanza la fruta.
- El hacha (**Alt**) se lanza hacia adelante; hay que **atacar con
  continuidad**, no un solo toque cada varios segundos.

---

## PROBLEMAS DEL AGENTE ACTUAL (v2)

El agente heurístico en `wboy_ai.lua` **no cumple** el estilo de juego humano:

1. **Casi no ataca** — solo lanza hacha cuando el enemigo está muy cerca
   (`AXE_RANGE = 36`) y un frame suelto; **debe atacar de forma continua**
   mientras avanza si hay enemigos delante (avispas, criaturas en el suelo).
2. **Salta tarde o poco** ante rocas, fuego y avispas — debe **saltar antes**
   de chocar, con ventana más amplia y manteniendo **→** en el aire.
3. **No combina salto + avance** para frutas — para coger bananas/manzanas
   hay que **pulsar salto y mantener →** (salto largo hacia adelante), no
   saltar en el sitio.

---

## CÓMO LEER LA PANTALLA / SPRITERAM

### Resolución y cámara

- Pantalla **256×224**, scroll lateral hacia la **derecha**.
- Tom-Tom suele estar en el **tercio izquierdo**; peligros y frutas entran por
  la derecha.

### Sprites relevantes (`SPRITE_BASE = 0xd000`, agente Lua)

| Tipo | Códigos sprite (hex) | Comportamiento |
|------|----------------------|----------------|
| **Jugador** | `0x82`, `0x83`, `0x84` | Tom-Tom |
| **Roca** | `0x7b`, `0x7c`, `0x7f` | Obstáculo en el suelo — **saltar** |
| **Fuego / llama** | `0x67`, `0x68`, `0x69`, `0xd8` | En el suelo o bajo — **saltar antes** |
| **Enemigo / avispa** | `0x48`, `0x49`, `0x4a`, `0x4b` | En carril o volando bajo — **hacha continua** o salto |
| **Fruta** | `0x87`, `0x8f`, `0x91` (+ `0x67` en contexto fruta) | Sobre o delante — **→ + salto sostenido** |
| **Herramienta** | `0x80`, `0x81`, `0x85`, `0x86` | Igual que fruta si está arriba |

Coordenadas en Lua: `sx = raw_x - 128`, `sy = 256 - raw_y`.

### Fases de pantalla

| Fase | Acción |
|------|--------|
| **Atractivo / título** | **5** → **1** |
| **Juego activo** | Estrategia completa |
| **Game Over** | **5** → **1** |

---

## ESTRATEGIA — REGLAS OBLIGATORIAS

### 1. Avanzar siempre

- **→ pulsado** en todo momento salvo retroceso de emergencia.
- No quedarse quieto en X; el nivel es progresión constante hacia la derecha.

### 2. Atacar enemigos de forma CONTINUA (hacha / “disparar”)

- Si hay **cualquier enemigo o avispa** delante en rango (~20–90 px) y en
  altura similar (|ΔY| < ~30 px): mantener **`axe = true` casi cada frame**
  (o alternar con cooldown mínimo de **2–4 frames**, no 12+).
- **No esperes** a que el enemigo esté a 20 px: ataca desde **distancia media**
  (~40–70 px) mientras corres.
- Si el enemigo vuela bajo (avispa): **hacha + →**; si está muy bajo y cerca,
  **salto + hacha** en el mismo tramo.
- Prioridad: **enemigo en tu carril > fruta lejana > avance vacío**.

### 3. Saltar rocas, fuego y avispas (chocar = muerte)

- **Roca en el suelo** (mismo carril, delante): saltar cuando `dx` esté en
  **~22–55 px** (ventana más temprana que v2), manteniendo **→**.
- **Fuego / llama**: saltar **antes** que la roca (ventana **~30–65 px**); el
  fuego mata al contacto.
- **Avispa / enemigo aéreo bajo**: si no basta el hacha, **salto** con **→**
  para pasar por encima sin perder velocidad.
- El salto debe durar **~20–26 frames** (`JUMP_HOLD`); un toque de 1 frame no
  sirve.

### 4. Coger frutas: salto con velocidad (→ + salto mantenido)

- Cuando una **fruta** esté delante y ligeramente **arriba** o en arco:
  - Activar **→ = true** y **jump = true** **a la vez** durante todo el salto.
  - No saltar parado ni soltar → en el aire.
- Ventana típica: fruta a **14–55 px** delante y **6–40 px** más arriba que el
  jugador.
- Tras coger la fruta, **seguir con →** al aterrizar; no frenar.

### 5. Herramientas (hacha extra, patines, etc.)

- Misma lógica que frutas: **→ + salto sostenido** hacia el item.
- Si hay herramienta y enemigo a la vez: **ataca** mientras avanzas; no ignores
  enemigos por la herramienta.

---

## PRIORIDAD DE DECISIÓN (cada frame)

```
1. ¿Fuego/roca/avispa en carril y dx en ventana de salto?  → → + SALTO (26 f)
2. ¿Enemigo delante (20–90 px)?                             → → + HACHA CONTINUA
3. ¿Fruta/herramienta arriba-delante?                       → → + SALTO sostenido
4. ¿Enemigo muy cerca (< 20 px) y hacha no bastó?            → → + SALTO
5. Si no hay nada                                           → → (+ hacha si hay enemigo lejano)
```

**Nunca** elijas solo `RUN` con enemigos visibles delante sin `axe = true`.

---

## BUCLE DE JUEGO

```
captura / lee sprites
  → localiza jugador, rocas, fuego, enemigos, frutas
  → decide: CORRE | ATACA | SALTA_PELIGRO | SALTA_FRUTA | HACHA+CORRE
  → aplica entradas (→ casi siempre ON; Ctrl/Alt sostenidos según modo)
  → repite
```

| Modo | Condición | Entradas P1 (Lua) |
|------|-----------|-------------------|
| **CORRE+ATACA** | Enemigo 20–90 px | RIGHT + AXE (cada frame o cooldown 2–4 f) |
| **SALTA_PELIGRO** | Roca/fuego/avispa en ventana | RIGHT + JUMP (~26 f) |
| **SALTA_FRUTA** | Fruta arriba-delante | RIGHT + JUMP (~26 f), → no soltar |
| **CORRE** | Camino libre | RIGHT |
| **HACHA_LEJOS** | Enemigo 40–90 px | RIGHT + AXE continuo |

---

## CAMBIOS CONCRETOS PARA `wboy_ai.lua`

Implementar o ajustar:

1. **`axe_continuous`**: si `enemy` delante y `dx < 90`, `axe = true` salvo
   cuando `jump` activo; cooldown de hacha **≤ 4 frames** (no apagar tras 1 f).
2. **`jump_window`**: ampliar rangos roca/fuego/enemigo (ver estrategia arriba).
3. **Frutas**: si `fruit` y `target.sy < player.sy - 4`, forzar `right=true`
   y `jump=true` durante `JUMP_HOLD` completo.
4. **Detección avispas**: tratar sprites enemigos con `sy` entre `player.sy - 20`
   y `player.sy + 15` como amenaza aérea baja → hacha + posible salto.
5. **Overlay**: mostrar `ATACA`, `SALTO-FRUTA`, `SALTO-FUEGO` para depurar.
6. **No reducir `axe`** cuando hay múltiples enemigos en pantalla; atacar
   mientras `scan_ahead` devuelve cualquier `enemy`.

Puertos Lua (`:P1`):

| Acción | Máscara |
|--------|---------|
| RIGHT | `0x40` |
| LEFT | `0x80` |
| JUMP | `0x02` |
| AXE | `0x04` |

---

## ARRANQUE (BOOT)

1. **5** (moneda) → **1** (start).
2. Repetir start cada ~2 s si sigue en título.
3. Tras entrar en juego, un salto inicial opcional para despegar del spawn.

Secuencia actual en `boot_sequence()` (frames 40–260): coin → start ×2 → salto.

---

## MODO ENSEÑAR

Grabar con `./scripts/teach_session.sh wonder_boy` o `wboy_record_play.lua`:

- Demostrar **→ + Alt** continuo al ver enemigos.
- Demostrar **→ + Ctrl** largo hacia frutas.
- Demostrar saltos **antes** de rocas/fuego, sin soltar →.

JSONL esperado:

```json
{"frame":N,"game":"wonder_boy","player":{"x":…,"y":…},"input":{"right":…,"left":…,"jump":…,"axe":…}}
```

Usar demos para calibrar ventanas de salto y duty cycle del hacha.

---

## OBJETIVO FINAL

Correr siempre a la derecha, **lanzar el hacha de forma continua** contra
enemigos y avispas, **saltar a tiempo** rocas/fuego/amenazas bajas, y **coger
frutas** con salto largo manteniendo **→** pulsado. Sobrevivir el máximo tramo
posible y maximizar puntuación por frutas.

---

## ANÁLISIS DEL VÍDEO DE REFERENCIA

**URL:** https://www.youtube.com/watch?v=605pJzgs330  
**Título:** Wonder Boy Rom + MAME Plus + FREE DOWNLOAD (canal MAME Roms)  
**Duración:** 5:36 — captura Bandicam de MAME, **gameplay real** del arcade 1986 (`wboy`).

> **No es Wonder Boy in Monster Land.** No hay tiendas, armaduras ni bombas.
> Es el original: correr →, barra de vitalidad, huevos, frutas, patinete.

### Momentos clave observados

| Tiempo | Escena | Puntuación | Vidas | Qué hace el jugador |
|--------|--------|------------|-------|---------------------|
| ~0:30 | **ROUND BONUS** (fin de ronda) | 18 580 | 4 | Bonus muñeca 6960; barra vitalidad media |
| ~0:55 | Patinete, plataformas | 5 440 | 3 | Salto entre islas **sin soltar →**; hacha en inventario |
| ~1:05 | Patinete sobre nubes/agua | 26 790 | 4 | Salta de nube en nube; inventario: hacha, collar, poción, zapatos |
| ~3:00 | Patinete en suelo | 5 040 | 4 | **Hacha continua** contra rana delante; barra roja+amarilla |
| ~4:00 | A pie, bosque | 84 360 | 4 | Corre hacia **fuego** en el suelo (salto inminente); hacha activa |

### Patrones de juego humano (extraídos del vídeo)

1. **→ casi siempre pulsado** — nunca se queda quieto en el cartel START ni en juego.
2. **Barra de vitalidad** (segmentos rojo/amarillo arriba) — baja sola; hay que **coger fruta**
   sin parar de avanzar.
3. **Huevos en el suelo** — se rompen **corriendo** (no saltando encima).
4. **Hacha** — cuando hay enemigo delante, **disparo continuo** (no un toque cada 2 s).
5. **Patinete (sprite 0x84)** — el scroll es automático; **no se puede frenar**;
   solo saltar fuego/roca/huevos malos y **huecos entre plataformas** (nubes).
6. **Inventario** (cuadro arriba-izq): hacha de piedra, collar (vida extra), poción, patines/zapatos.
7. **Fuego en el suelo** — saltar **antes** de llegar (frame ~4:00: corre y salta con antelación).
8. **Fin de ronda** — cartel GOAL → bonus muñeca; no aplica lógica de combate.

### Mapeo vídeo → `wboy_ai.lua` v16

| Comportamiento del vídeo | Modo Lua |
|--------------------------|----------|
| Pasar cartel START | `ARRANQUE` (→ 6 s tras boot) |
| Correr + romper huevo | `ROMPE-HUEVO` |
| Correr + fruta en suelo | `COGE-FRUTA` |
| Hacha a rana/enemigo | `ATACA` / `PATINETE` + `want_axe` |
| Salto sobre fuego | `SALTO-FUEGO` |
| Patinete sin frenar | `PATINETE` |
| Saltos nube/plataforma | `SKATE-NUBE` |
| Fruta en el aire | `SALTO-FRUTA` |

### Overlay de depuración

- `AI v16 CORRE R1 [W|IO]` — **R1** = input derecha activo en MAME; **R0** = bug de inputs.
- `W` = tiene hacha; `S` = en patinete.
