#!/usr/bin/env python3
"""Лабиринт 2-го этажа (акт 4–6): сетка по осям настоящих стен здания (через 3 м), блоки — сохранённые
помещения (палата 204, процедурная 213, лестницы, шахта лифта). Печатает GDScript-константы со стенами.
Запуск: python3 make_maze.py [картинка.png]"""
import random
import sys
from collections import deque

XS = [0.3] + [3.0 * k for k in range(1, 16)]            # 0.3, 3, 6, ..., 45
ZS = [-15.8, -12.7, -9.6, -6.6, -3.45, -0.3]            # ряды: 0 юг ... 4 север
NC, NR = len(XS) - 1, len(ZS) - 1
BLOCK = {(1, 0), (2, 0), (1, 1), (2, 1),               # лестница №2
         (2, 3), (3, 3), (2, 4), (3, 4),               # палата 204 (+ санузел)
         (10, 0), (10, 1),                             # процедурная 213
         (10, 3), (11, 3), (12, 3), (10, 4), (11, 4), (12, 4)}   # лестница №1 + шахта лифта
LIFT = (12, 2)
DOOR204 = [(2, 2), (3, 2)]       # дверь 204 приходится на стык двух клеток — между ними стены нет
KEY = (10, 2)                    # перед дверью 213 (и перед дверью лестницы №1)
cells = [(c, r) for c in range(NC) for r in range(NR) if (c, r) not in BLOCK]


def nbrs(c, r):
    for dc, dr in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        q = (c + dc, r + dr)
        if 0 <= q[0] < NC and 0 <= q[1] < NR and q not in BLOCK:
            yield q


def build(seed):
    rnd = random.Random(seed)
    opened = set()
    seen = {LIFT}
    stack = [LIFT]
    while stack:
        cur = stack[-1]
        cand = [q for q in nbrs(*cur) if q not in seen]
        if not cand:
            stack.pop()
            continue
        q = rnd.choice(cand)
        opened.add(frozenset((cur, q)))
        seen.add(q)
        stack.append(q)
    opened.add(frozenset(DOOR204))
    # несколько лишних проходов — чтобы были петли
    walls = [frozenset((a, b)) for a in cells for b in nbrs(*a) if a < b and frozenset((a, b)) not in opened]
    rnd.shuffle(walls)
    for w in walls[:6]:
        opened.add(w)
    return opened


def dist(opened, src):
    d = {src: 0}
    dq = deque([src])
    while dq:
        a = dq.popleft()
        for b in nbrs(*a):
            if frozenset((a, b)) in opened and b not in d:
                d[b] = d[a] + 1
                dq.append(b)
    return d


best = None
for seed in range(1, 400):
    op = build(seed)
    d0 = dist(op, LIFT)
    dk = dist(op, KEY)
    if len(d0) != len(cells):
        continue
    score = d0[KEY] * 0.5 + dk[DOOR204[0]] + (0 if d0[KEY] >= 4 else -20)
    if best is None or score > best[0]:
        best = (score, seed, op, d0[KEY], dk[DOOR204[0]])
score, seed, opened, dkey, d204 = best
print("# seed %d: от лифта до ключа %d клеток, от ключа до 204 — %d" % (seed, dkey, d204), file=sys.stderr)

# стены: вертикальные (между столбцами) и горизонтальные (между рядами)
out = []
ROUTE_ROW = 2
for r in range(NR):
    for c in range(NC + 1):
        a, b = (c - 1, r), (c, r)
        ina = 0 <= a[0] < NC and a not in BLOCK
        inb = c < NC and b not in BLOCK
        if not ina and not inb:
            continue
        if ina and inb and frozenset((a, b)) in opened:
            continue
        x = XS[c]
        side = 0 if (ina and inb) else (-1 if ina else 1)    # с какой стороны клетка лабиринта
        fall = 1 if (ina and inb and r == ROUTE_ROW and 3 <= c <= 10) else 0
        out.append((x, ZS[r], x, ZS[r + 1], side, fall))
for c in range(NC):
    for r in range(NR + 1):
        a, b = (c, r - 1), (c, r)
        ina = 0 <= a[1] < NR and a not in BLOCK
        inb = r < NR and b not in BLOCK
        if not ina and not inb:
            continue
        if ina and inb and frozenset((a, b)) in opened:
            continue
        z = ZS[r]
        side = 0 if (ina and inb) else (-1 if ina else 1)
        out.append((XS[c], z, XS[c + 1], z, side, 0))
print("const MAZE_SEED := %d" % seed)
print("## [x0, z0, x1, z1, сторона клетки (-1 / 0 / 1), падает в землетрясение (1)]")
print("const MAZE_WALLS := [")
for w in out:
    print("\t[%.2f, %.2f, %.2f, %.2f, %d, %d]," % w)
print("]")
if len(sys.argv) > 1:
    from PIL import Image, ImageDraw
    S = 22
    img = Image.new("RGB", (int(46 * S), int(17 * S)), (40, 40, 40))
    d = ImageDraw.Draw(img)
    X = lambda x: x * S + 10
    Z = lambda z: (z + 16.3) * S
    for (c, r) in BLOCK:
        d.rectangle([X(XS[c]), Z(ZS[r]), X(XS[c + 1]), Z(ZS[r + 1])], fill=(90, 60, 60))
    for (c, r), col in ((LIFT, (60, 60, 160)), (KEY, (160, 160, 40)), (DOOR204[0], (40, 140, 40)), (DOOR204[1], (40, 140, 40))):
        d.rectangle([X(XS[c]) + 3, Z(ZS[r]) + 3, X(XS[c + 1]) - 3, Z(ZS[r + 1]) - 3], fill=col)
    for x0, z0, x1, z1, side, fall in out:
        d.line([X(x0), Z(z0), X(x1), Z(z1)], fill=(255, 120, 0) if fall else (230, 230, 230), width=4)
    img.save(sys.argv[1])
