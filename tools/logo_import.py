#!/usr/bin/env python3
"""logo_import.py — картинка ANSI-логотипа → logos/<имя>.png для about.

Обрезает по содержимому (фон тёмный), поле 6 px, ширина не больше 1600.
Всё, что лежит в logos/*.png, about показывает в ротации с текстовыми.

  python3 tools/logo_import.py ИМЯ ФАЙЛ [ИМЯ ФАЙЛ ...]
"""
import sys, os
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'logos')

def imp(name, src):
    im = Image.open(src).convert('RGB'); W, H = im.size; px = im.load()
    xs = []; ys = []
    for y in range(H):
        for x in range(W):
            if sum(px[x, y]) > 90: xs.append(x); ys.append(y)
    if not xs: print('empty', src); return
    m = 6
    im = im.crop((max(0, min(xs) - m), max(0, min(ys) - m), min(W, max(xs) + 1 + m), min(H, max(ys) + 1 + m)))
    if im.width > 1600: im = im.resize((1600, round(im.height * 1600 / im.width)), Image.LANCZOS)
    im.save(os.path.join(OUT, name + '.png'), optimize=True)
    print(name, im.size)

a = sys.argv[1:]
for i in range(0, len(a) - 1, 2): imp(a[i], a[i + 1])
