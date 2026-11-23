#!/usr/bin/env python3
"""Текстуры бумаг в палате деда (story/notes/): телеграмма в картонной папке, бланк направления
и записка карандашом на тетрадном листе. На бумаге — тот же текст, что в игре (story/director.gd, NOTES):
его можно прочитать, если подъехать близко. Бумага старая: желтизна, пятна, сгиб.
Запуск: python3 make_note_textures.py <папка the_last_shake/story/notes>"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(1975)
FONTS = "/usr/share/fonts/truetype/dejavu/"
W, H = 600, 848            # А4

# Телеграмма от Дилором деду. Во сне всё сходится и не сходится одновременно — Азиз этого не замечает:
# в телеграмме 1980 год, а в направлении 1975-й; «Азиз уже бегает» — а он в коляске; в записке дед пишет, что
# внуков у него нет, — а в направлении записан внук.
MOM = ("ТАШКЕНТ 14/XI 1980 14 40\n\n"
       "САНАТОРИЙ ОРОМГОХ ПАЛАТА 204 КАРИМОВУ А К\n\n"
       "ПАПА ПРИЕДЕМ ВОСКРЕСЕНЬЕ ВДВОЁМ АЗИЗОМ ТЧК "
       "АЗИЗ УЖЕ БЕГАЕТ ВО ДВОРЕ С РЕБЯТАМИ ВРАЧ ГОВОРИТ ЧУДО ТЧК "
       "НЕ ВОЛНУЙСЯ ЖДИ ТЧК\n\nДИЛОРОМ")
FORM = [("Дата", "10 ноября 1975 г."), ("Ф. И. О.", "Каримов Анвар Каримович"), ("Возраст", "74 года"),
        ("Диагноз", "стенокардия; невроз после смерти жены"), ("", "бессонница, отказывается от еды"),
        ("Санаторий", "«Оромгох», 2 этаж, палата 204"), ("Срок", "45 дней"),
        ("Родные", "дочь Дилором; внук Азиз, 16 лет (коляска)"), ("Отметка", "острые предметы из палаты убрать")]
PENCIL = ("Дилором звонила. Голос какой-то не её. Говорит, в воскресенье приедут с Азизом. "
          "Я не стал её расстраивать — не сказал, что внуков у меня нет.\n\n"
          "Здесь никто не спит. Ночью кто-то идёт по коридору и стучит в каждую дверь — три раза. "
          "Я считаю двери. До моей он ещё не дошёл.\n\n"
          "Санитар говорит, в 139-й давно никого нет. Я спросил, кто же там тогда кричит. "
          "Он засмеялся и выключил мне свет.\n\n"
          "Я устал. Если утром меня найдут — не будите. Пусть Азиз меня таким не видит.\n— А.")


def paper(w, h, base=(226, 218, 196), lines=False):
    a = np.ones((h, w, 3), np.float32) * np.array(base, np.float32)
    n = rng.standard_normal((h // 8 + 1, w // 8 + 1)).astype(np.float32)
    big = np.asarray(Image.fromarray(n).resize((w, h), Image.BICUBIC))
    fine = rng.standard_normal((h, w)).astype(np.float32)
    a *= (1.0 + big[..., None] * 0.025 + fine[..., None] * 0.012)
    yy, xx = np.mgrid[0:h, 0:w]
    edge = np.minimum(np.minimum(xx, w - xx), np.minimum(yy, h - yy)) / 40.0
    a *= (0.86 + 0.14 * np.clip(edge, 0, 1))[..., None]
    for _ in range(3):                                   # следы от стакана
        cx, cy, r = rng.uniform(0, w), rng.uniform(0, h), rng.uniform(25, 70)
        d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / r
        ring = np.exp(-((d - 1.0) / 0.08) ** 2) * 0.12 + (d < 1.0) * 0.04
        a *= (1.0 - ring[..., None] * np.array([0.6, 0.8, 1.0])[None, None, :])
    a *= (1.0 - np.exp(-((yy - h * 0.5) / 2.0) ** 2) * 0.08)[..., None]     # сгиб пополам
    img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    if lines:
        d = ImageDraw.Draw(img)
        for y in range(70, h - 30, 26):
            d.line([(20, y), (w - 20, y)], fill=(160, 175, 200), width=1)
        d.line([(60, 0), (60, h)], fill=(200, 120, 120), width=1)
    return img


def wrap(draw, text, font, width):
    out = []
    for para in text.split("\n"):
        cur = ""
        for wd in para.split(" "):
            t = (cur + " " + wd).strip()
            if draw.textlength(t, font=font) <= width:
                cur = t
            else:
                out.append(cur)
                cur = wd
        out.append(cur)
    return out


def text_block(img, text, font, x, y, width, fill, step, jitter=0.0):
    d = ImageDraw.Draw(img)
    for ln in wrap(d, text, font, width):
        d.text((x + rng.uniform(-jitter, jitter), y + rng.uniform(-jitter, jitter) * 0.5), ln, font=font, fill=fill)
        y += step
        if y > img.height - 30:
            break


def save(img, name):
    img.filter(ImageFilter.GaussianBlur(0.35)).save(os.path.join(OUT, name), quality=90)
    print("wrote", name)


mono = ImageFont.truetype(FONTS + "DejaVuSansMono.ttf", 15)
mono_b = ImageFont.truetype(FONTS + "DejaVuSansMono-Bold.ttf", 17)
serif = ImageFont.truetype(FONTS + "DejaVuSerif.ttf", 14)
serif_b = ImageFont.truetype(FONTS + "DejaVuSerif-Bold.ttf", 17)
# рукописный шрифт с кириллицей: Bad Script (Google Fonts, лицензия OFL) — лежит рядом, в fonts/
hand = ImageFont.truetype(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts", "BadScript-Regular.ttf"), 19)

# --- телеграмма: бланк с шапкой, текст на наклеенных полосках телеграфной ленты, штамп отделения связи
img = paper(W, H, base=(214, 205, 178))
d = ImageDraw.Draw(img)
d.text((40, 36), "МИНИСТЕРСТВО СВЯЗИ СССР", font=serif, fill=(70, 50, 40))
d.text((W // 2 - 95, 66), "ТЕЛЕГРАММА", font=ImageFont.truetype(FONTS + "DejaVuSerif-Bold.ttf", 30), fill=(120, 40, 30))
d.line([(40, 112), (W - 40, 112)], fill=(120, 60, 50), width=2)
y = 140
for para in MOM.split("\n"):
    for ln in wrap(d, para, mono_b, W - 110) if para else [""]:
        if ln:
            tw = d.textlength(ln, font=mono_b)
            strip = Image.new("RGB", (int(tw) + 16, 26), (236, 232, 214))
            sdr = ImageDraw.Draw(strip)
            sdr.text((8, 3), ln, font=mono_b, fill=(40, 40, 45))
            img.paste(strip.rotate(rng.uniform(-0.6, 0.6), expand=False, fillcolor=(214, 205, 178)), (45, y))
        y += 34
st = Image.new("RGBA", (150, 150), (0, 0, 0, 0))
sd = ImageDraw.Draw(st)
sd.ellipse((5, 5, 145, 145), outline=(60, 70, 150, 170), width=4)
sd.ellipse((25, 25, 125, 125), outline=(60, 70, 150, 150), width=2)
sd.text((32, 58), "ТАШКЕНТ", font=mono_b, fill=(60, 70, 150, 170))
sd.text((40, 80), "14.11.80", font=mono, fill=(60, 70, 150, 170))
img.paste(st.rotate(18), (W - 210, H - 230), st.rotate(18))
save(img, "note_typed.jpg")

# --- бланк направления: типографские строки, ответы чернилами от руки
img = paper(W, H, base=(222, 222, 205))
d = ImageDraw.Draw(img)
d.text((40, 36), "Министерство здравоохранения УзССР", font=serif, fill=(40, 40, 40))
d.text((40, 70), "НАПРАВЛЕНИЕ", font=serif_b, fill=(30, 30, 30))
d.text((40, 94), "на санаторно-курортное лечение · форма 070/у", font=serif, fill=(40, 40, 40))
for i, (lab, val) in enumerate(FORM):
    y = 150 + i * 46
    d.text((40, y), lab, font=serif, fill=(40, 40, 40))
    d.line([(140, y + 22), (W - 40, y + 22)], fill=(90, 90, 90), width=1)
    d.text((150 + rng.uniform(-3, 3), y - 2), val, font=hand, fill=(30, 40, 110))
d.text((W - 230, H - 120), "Врач: ______ подпись", font=serif, fill=(40, 40, 40))
save(img, "note_form.jpg")

# --- записка карандашом на тетрадном листе
img = paper(W, H, base=(230, 228, 214), lines=True)
text_block(img, PENCIL, hand, 72, 50, W - 100, (85, 85, 92), 26, 1.2)
save(img, "note_pencil.jpg")

# --- картонная папка «Дело»
img = paper(640, 880, base=(196, 170, 120))
d = ImageDraw.Draw(img)
d.rectangle((40, 40, 600, 840), outline=(120, 95, 60), width=3)
d.text((230, 120), "ДЕЛО №", font=ImageFont.truetype(FONTS + "DejaVuSerif-Bold.ttf", 34), fill=(70, 50, 30))
d.line([(220, 175), (440, 175)], fill=(70, 50, 30), width=2)
d.text((150, 230), "Санаторий «Оромгох»", font=ImageFont.truetype(FONTS + "DejaVuSerif.ttf", 26), fill=(70, 50, 30))
save(img, "note_folder.jpg")
