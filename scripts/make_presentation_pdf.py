#!/usr/bin/env python3
"""Генератор PDF-презентации «Препресс-Планер»: 7 слайдов 16:9, вектор."""
import os
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, white
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

W, H = 960, 540
M = 56
TOTAL = 7
SUP = "/System/Library/Fonts/Supplemental"

PAPER = HexColor("#F7F6F2")
INK = HexColor("#101828")
GREY = HexColor("#5B6472")
RULE = HexColor("#D8D5CC")
CYAN = HexColor("#0E7FC0")
CYAN_LT = HexColor("#4DB1E8")
CARD = white
CARD_LINE = HexColor("#E4E1D8")
DARK_BG = INK
DARK_CARD = HexColor("#1A2434")
DARK_LINE = HexColor("#33405A")
DARK_TEXT = HexColor("#9AA3B2")
DARK_BODY = HexColor("#6B7484")
HATCH = HexColor("#A8CBE4")
CELL_HL = HexColor("#D7E9F6")

F = "Arial"
FB = "Arial-Bold"
FI = "Arial-Italic"
FK = "Arial-Black"


def register_fonts():
    pdfmetrics.registerFont(TTFont(F, f"{SUP}/Arial.ttf"))
    pdfmetrics.registerFont(TTFont(FB, f"{SUP}/Arial Bold.ttf"))
    pdfmetrics.registerFont(TTFont(FI, f"{SUP}/Arial Italic.ttf"))
    pdfmetrics.registerFont(TTFont(FK, f"{SUP}/Arial Black.ttf"))


def sw(text, font, size):
    return pdfmetrics.stringWidth(text, font, size)


def yb(top):
    return H - top


def wrap(text, font, size, maxw):
    lines, cur = [], ""
    for word in text.split():
        trial = (cur + " " + word).strip()
        if sw(trial, font, size) <= maxw:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def block(c, x, top, text, font, size, leading, maxw, color, max_lines=None):
    """Рисует абзац. top — базовая линия первой строки (от верха). Возвращает top после блока."""
    lines = wrap(text, font, size, maxw)
    if max_lines is not None:
        lines = lines[:max_lines]
    c.setFont(font, size)
    c.setFillColor(color)
    y = top
    for ln in lines:
        c.drawString(x, yb(y), ln)
        y += leading
    return y


def track(c, x, top, text, font, size, tr, color):
    c.setFont(font, size)
    c.setFillColor(color)
    cx, y = x, yb(top)
    for ch in text:
        c.drawString(cx, y, ch)
        cx += sw(ch, font, size) + tr
    return cx


def card(c, x, top, w, h, fill=CARD, stroke=CARD_LINE, r=6, lw=0.75):
    c.setFillColor(fill)
    c.setStrokeColor(stroke)
    c.setLineWidth(lw)
    c.roundRect(x, yb(top) - h, w, h, r, stroke=1, fill=1)


def crop_marks(c, dark=False):
    col = DARK_LINE if dark else RULE
    c.setStrokeColor(col)
    c.setLineWidth(0.8)
    i, arm = 22, 14
    c.line(i, H - i, i, H - i - arm)
    c.line(i, H - i, i + arm, H - i)
    c.line(W - i, H - i, W - i, H - i - arm)
    c.line(W - i, H - i, W - i - arm, H - i)
    c.line(i, i, i, i + arm)
    c.line(i, i, i + arm, i)
    c.line(W - i, i, W - i, i + arm)
    c.line(W - i, i, W - i - arm, i)
    # приводочная метка (registration crosshair) справа сверху
    cx, cy, r = W - i - 4, H - i - 4, 5
    c.setStrokeColor(CYAN_LT if dark else CYAN)
    c.setLineWidth(0.7)
    c.circle(cx, cy, r, stroke=1, fill=0)
    c.line(cx - r - 4, cy, cx + r + 4, cy)
    c.line(cx, cy - r - 4, cx, cy + r + 4)


def chrome(c, kicker, num, dark=False):
    kick_col = CYAN_LT if dark else CYAN
    foot_col = DARK_BODY if dark else GREY
    rule_col = DARK_LINE if dark else RULE
    track(c, M, 56, kicker, FB, 9, 1.6, kick_col)
    c.setStrokeColor(rule_col)
    c.setLineWidth(0.75)
    c.line(M, yb(498), W - M, yb(498))
    c.setFont(F, 8.5)
    c.setFillColor(foot_col)
    c.drawString(M, yb(514), "Препресс-Планер · продуктовая презентация")
    c.setFont(FB, 8.5)
    c.drawRightString(W - M, yb(514), f"{num:02d} / {TOTAL:02d}")


def title(c, text, top=96, size=26, color=INK):
    c.setFont(FB, size)
    c.setFillColor(color)
    c.drawString(M, yb(top), text)


def intro(c, text, top=126, maxw=760, size=12.5):
    block(c, M, top, text, F, size, 17, maxw, GREY)


def hatch(c, x, y, w, h, step=8, color=HATCH, lw=0.6):
    """Диагональная штриховка внутри прямоугольника (y — низ, PDF-координаты)."""
    c.saveState()
    c.setStrokeColor(color)
    c.setLineWidth(lw)
    x2, y2 = x + w, y + h
    b = (y - x2) - 1
    while b <= (y2 - x) + 1:
        pts = []
        for xx, yy in ((x, x + b), (x2, x2 + b), (y - b, y), (y2 - b, y2)):
            if x <= xx <= x2 and y <= yy <= y2:
                rp = (round(xx, 2), round(yy, 2))
                if rp not in pts:
                    pts.append(rp)
        if len(pts) >= 2:
            c.line(pts[0][0], pts[0][1], pts[1][0], pts[1][1])
        b += step
    c.restoreState()


def dim_h(c, x1, x2, top, label, color=GREY, size=8.5, tick=3, above=True):
    y = yb(top)
    c.setStrokeColor(color)
    c.setLineWidth(0.6)
    c.line(x1, y, x2, y)
    for xx in (x1, x2):
        c.line(xx, y - tick, xx, y + tick)
    c.setFont(F, size)
    c.setFillColor(color)
    tw = sw(label, F, size)
    ly = y + 7 if above else y - 5 - size * 0.8
    c.drawString((x1 + x2) / 2 - tw / 2, ly, label)


def dim_v(c, x, y1, y2, label, color=GREY, size=8.5, tick=3):
    """Вертикальная размерная линия; label рисуется вертикально (снизу вверх)."""
    c.setStrokeColor(color)
    c.setLineWidth(0.6)
    c.line(x, y1, x, y2)
    for yy in (y1, y2):
        c.line(x - tick, yy, x + tick, yy)
    c.saveState()
    c.translate(x - 4, (y1 + y2) / 2)
    c.rotate(90)
    c.setFont(F, size)
    c.setFillColor(color)
    tw = sw(label, F, size)
    c.drawString(-tw / 2, 4, label)
    c.restoreState()


def check_badge(c, cx, cy, r=9, color=CYAN):
    c.setFillColor(color)
    c.setStrokeColor(color)
    c.circle(cx, cy, r, stroke=0, fill=1)
    c.setStrokeColor(white)
    c.setLineWidth(1.6)
    p = c.beginPath()
    p.moveTo(cx - r * 0.45, cy)
    p.lineTo(cx - r * 0.12, cy - r * 0.38)
    p.lineTo(cx + r * 0.45, cy + r * 0.38)
    c.drawPath(p, stroke=1, fill=0)


# --------------------------------------------------------------------------
# Слайд 1 — обложка (тёмная)
# --------------------------------------------------------------------------
def slide_cover(c):
    c.setFillColor(DARK_BG)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c, dark=True)

    c.setFillColor(CYAN_LT)
    c.rect(M, yb(79), 46, 3, stroke=0, fill=1)
    c.setFont(FB, 46)
    c.setFillColor(white)
    c.drawString(M, yb(128), "Препресс-Планер")
    y = block(
        c, M, 170,
        "Планирование расходных материалов и экономико-технического "
        "обоснования (ТЭО) тиражей этикеток",
        F, 15, 22, 452, DARK_TEXT,
    )
    block(
        c, M, y + 14,
        "От файла заказчика — к раскрою, себестоимости и готовым отчётам.",
        FB, 12, 17, 452, CYAN_LT,
    )

    # правая панель: step-and-repeat сетка этикеток
    px, ptop, pw, ph = 548, 120, 340, 260
    c.setStrokeColor(DARK_LINE)
    c.setLineWidth(1)
    c.rect(px, yb(ptop) - ph, pw, ph, stroke=1, fill=0)
    ix, iy = px + 20, yb(ptop) - 20          # левый верх внутренней зоны (PDF-коорд.)
    iw, ih = pw - 40, ph - 40
    cols, rows, cw, gap = 4, 4, 69.0, 8.0
    ch = cw * 30 / 50
    grid_h = rows * ch + (rows - 1) * gap
    for r in range(rows):
        for k in range(cols):
            cx = ix + k * (cw + gap)
            cy = iy - grid_h + r * (ch + gap)
            hl = (r == 1 and k == 2)
            if hl:
                c.setFillColor(HexColor("#14324A"))
                c.setStrokeColor(CYAN_LT)
                c.setLineWidth(1.4)
            else:
                c.setFillColor(DARK_BG)
                c.setStrokeColor(HexColor("#3E4C66"))
                c.setLineWidth(0.8)
            c.roundRect(cx, cy, cw, ch, 3, stroke=1, fill=1)
    # зона отходов внизу сетки
    waste_y = iy - grid_h - 4
    hatch(c, ix, waste_y - 26, iw, 26, step=9, color=HexColor("#2A3448"), lw=0.6)
    # размерная линия над панелью
    dim_h(c, px, px + pw, ptop - 10, "полотно · шаг 53 × 33 мм", color=DARK_BODY, size=8.5)
    # приводочная метка на углу панели
    c.setStrokeColor(CYAN_LT)
    c.setLineWidth(0.8)
    c.circle(px + pw - 16, yb(ptop) - 16, 5, stroke=1, fill=0)
    c.line(px + pw - 25, yb(ptop) - 16, px + pw - 7, yb(ptop) - 16)
    c.line(px + pw - 16, yb(ptop) - 25, px + pw - 16, yb(ptop) - 7)
    c.setFont(FI, 9)
    c.setFillColor(DARK_BODY)
    c.drawString(px, yb(ptop + ph) + 18, "Этикетка 50 × 30 мм · зазор 3 мм · Z = 96")

    # низ
    track(c, M, 456, "iOS · WINDOWS · MACOS · LINUX · WEB", FB, 10.5, 1.4, white)


# --------------------------------------------------------------------------
# Слайд 2 — проблема
# --------------------------------------------------------------------------
def slide_problem(c):
    c.setFillColor(PAPER)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c)
    chrome(c, "01 · ПРОБЛЕМА", 2)
    title(c, "Что мешает считать тираж вручную")
    intro(c, "Тираж считается в Excel, «на глаз» и с запасом — каждый шаг дороже предыдущего.")

    items = [
        ("01", "Ручной перебор раскроя",
         "Сколько рядов и колонок, 0° или 90°? Варианты перебираются руками, а не алгоритмом."),
        ("02", "Ошибки входной геометрии",
         "Разрывы, пересечения, дубликаты и «пыль» в файлах заказчика всплывают уже на печати."),
        ("03", "ТЭО в разрозненных таблицах",
         "Сортамент, машиночасы, переналадка и наценки живут в разных файлах и не сходятся."),
        ("04", "Неизвестная себестоимость",
         "Отходы и цена 1000 шт становятся известны постфактум — после запуска тиража."),
    ]
    gap, top, ch = 16, 152, 220
    cw = (W - 2 * M - 3 * gap) / 4
    for i, (num, head, body) in enumerate(items):
        x = M + i * (cw + gap)
        card(c, x, top, cw, ch)
        c.setFillColor(CYAN)
        c.setFont(FK, 16)
        c.drawString(x + 18, yb(top + 34), num)
        y = block(c, x + 18, top + 66, head, FB, 12.5, 15, cw - 36, INK, max_lines=2)
        block(c, x + 18, y + 14, body, F, 10.5, 14.5, cw - 36, GREY, max_lines=6)

    # итоговая плашка
    st, sh = 400, 62
    card(c, M, st, W - 2 * M, sh, fill=HexColor("#EAF3FA"),
         stroke=HexColor("#C9DEF0"))
    c.setFillColor(CYAN)
    c.rect(M, yb(st) - sh, 4, sh, stroke=0, fill=1)
    c.setFont(FB, 13)
    c.setFillColor(INK)
    c.drawString(M + 22, yb(st + 37),
                 "Всё это — один файл проекта: без Excel, без «на глаз» и без сюрпризов на печати.")


# --------------------------------------------------------------------------
# Слайд 3 — сквозной сценарий (пайплайн)
# --------------------------------------------------------------------------
def slide_pipeline(c):
    c.setFillColor(PAPER)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c)
    chrome(c, "02 · СЦЕНАРИЙ", 3)
    title(c, "Сквозной сценарий: от файла до отчёта")
    intro(c, "Один проект ведёт файл через семь шагов — каждый шаг сохраняется и пересчитывается.")

    steps = [
        ("Импорт", "мультиформатность"),
        ("Диагностика", "разрывы, пересечения,\nдубликаты"),
        ("Лечение", "морфология\nи топология"),
        ("Массив", "step & repeat\nили сетка"),
        ("Раскрой", "расход по форме,\nперебор вариантов"),
        ("ТЭО", "себестоимость,\nточка безубыточности"),
        ("Отчёты", "PDF, XLSX,\nDXF"),
    ]
    n = len(steps)
    slot = (W - 2 * M) / n
    cy_top = 210                     # центр ленты (от верха)
    cy = yb(cy_top)
    r = 21
    # лента полотна
    c.setStrokeColor(HexColor("#C9D5E2"))
    c.setLineWidth(1.2)
    c.line(M, cy, W - M, cy)
    c.setStrokeColor(HexColor("#E1E7EE"))
    c.setLineWidth(0.8)
    c.line(M, cy - 7, W - M, cy - 7)
    c.line(M, cy + 7, W - M, cy + 7)

    for i, (head, sub) in enumerate(steps):
        cx = M + slot * (i + 0.5)
        # узел
        c.setFillColor(PAPER)
        c.setStrokeColor(CYAN)
        c.setLineWidth(1.5)
        c.circle(cx, cy, r, stroke=1, fill=1)
        c.setFillColor(CYAN)
        c.setFont(FK, 13)
        num = str(i + 1)
        c.drawString(cx - sw(num, FK, 13) / 2, cy - 4.5, num)
        # подписи
        c.setFillColor(INK)
        c.setFont(FB, 10.5)
        c.drawString(cx - sw(head, FB, 10.5) / 2, yb(cy_top + 48), head)
        lines = sub.split("\n")
        c.setFont(F, 9)
        c.setFillColor(GREY)
        for j, ln in enumerate(lines):
            c.drawString(cx - sw(ln, F, 9) / 2, yb(cy_top + 66 + j * 12), ln)

    # артефакты проекта
    c.setFont(FB, 9)
    c.setFillColor(GREY)
    track(c, M, 330, "АРТЕФАКТЫ ПРОЕКТА", FB, 9, 1.6, GREY)
    st, sh = 348, 52
    card(c, M, st, W - 2 * M, sh)
    c.setFont(F, 11)
    c.setFillColor(INK)
    chain = ("01_Исходник  →  02_Вылеченный_Мастер  →  03_Раскрой  →  "
             "04_ТЭО_Отчёт  →  05_Расчёт  →  сохранение проекта")
    c.drawString(M + (W - 2 * M) / 2 - sw(chain, F, 11) / 2, yb(st + 31), chain)
    block(c, M, 430,
          "Файлы и параметры живут в проекте: можно вернуться на любой шаг и пересчитать тираж.",
          FI, 10.5, 15, 700, GREY)


# --------------------------------------------------------------------------
# Слайд 4 — ключевые функции
# --------------------------------------------------------------------------
def slide_features(c):
    c.setFillColor(PAPER)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c)
    chrome(c, "03 · ВОЗМОЖНОСТИ", 4)
    title(c, "Что умеет программа")
    intro(c, "Шесть блоков, которые закрывают день технолога, экономиста и менеджера тиражей.")

    items = [
        ("Импорт форматов",
         "DXF, SVG и PDF — локально; AI, CDR и EPS — серверная конвертация в SVG/PDF."),
        ("Диагностика и лечение",
         "Находит разрывы, пересечения, дубли, пыль и острые углы — и лечит геометрию."),
        ("Массивы step & repeat",
         "Распознаёт готовый массив заказчика или генерирует сетку с шагом шестерни Z (раппорт)."),
        ("Расход по форме этикетки",
         "Считает по чистой площади контура, а не W×H: зазоры, ряды, 0°/90°, минимум отходов."),
        ("ТЭО за один перебор",
         "Сортамент, машиночасы, переналадка и смена → себестоимость 1000 шт и точка безубыточности."),
        ("Готовые отчёты",
         "PDF ТЭО, XLSX с расчётами, DXF мастера и раскроя — в один клик."),
    ]
    gap, top, ch = 16, 144, 160
    cw = (W - 2 * M - 2 * gap) / 3
    for i, (head, body) in enumerate(items):
        x = M + (i % 3) * (cw + gap)
        y0 = top + (i // 3) * (ch + gap)
        card(c, x, y0, cw, ch)
        c.setFillColor(CYAN)
        c.rect(x + 18, yb(y0 + 22), 24, 2.5, stroke=0, fill=1)
        y = block(c, x + 18, y0 + 52, head, FB, 13.5, 17, cw - 36, INK, max_lines=2)
        block(c, x + 18, y + 16, body, F, 10.5, 14.5, cw - 36, GREY, max_lines=5)


# --------------------------------------------------------------------------
# Слайд 5 — как считается (эталонный расчёт)
# --------------------------------------------------------------------------
def slide_calc(c):
    c.setFillColor(PAPER)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c)
    chrome(c, "04 · РАСЧЁТ", 5)
    title(c, "Как это считается: эталонный расчёт")
    intro(c, "Пример из тестов: те же формулы считаются на вашем файле за секунды.")

    # --- схема раскроя ---
    wx, wtop, ww, wh = M, 150, 400, 250
    card(c, wx, wtop, ww, wh, fill=white, stroke=INK, r=4, lw=1)
    pad = 18
    ix, itop = wx + pad, wtop + pad
    avail_w, avail_h = ww - 2 * pad, wh - 2 * pad
    cols, rows, cu_w, cu_h, cu_g = 9, 5, 50, 30, 3
    unit_w = cols * cu_w + (cols - 1) * cu_g
    unit_h = rows * cu_h + (rows - 1) * cu_g
    s = avail_w / unit_w
    cw, chh, g = cu_w * s, cu_h * s, cu_g * s
    grid_w = cols * cw + (cols - 1) * g
    grid_h = rows * chh + (rows - 1) * g
    for r in range(rows):
        for k in range(cols):
            x = ix + k * (cw + g)
            y = itop + r * (chh + g)   # отмеряем вниз от верха зоны
            top_c = y
            fill = CELL_HL if (r == 1 and k == 3) else white
            stroke_c = CYAN if (r == 1 and k == 3) else HexColor("#98A2B3")
            c.setFillColor(fill)
            c.setStrokeColor(stroke_c)
            c.setLineWidth(0.5 if fill is white else 1)
            c.roundRect(x, yb(top_c) - chh, cw, chh, 1.5, stroke=1, fill=1)
    # зона отходов под сеткой
    waste_top = itop + grid_h + 6
    waste_h = avail_h - grid_h - 6
    if waste_h > 6:
        hatch(c, ix, yb(waste_top) - waste_h, grid_w, waste_h, step=9)
        c.setFont(FI, 9)
        c.setFillColor(GREY)
        c.drawString(ix + 4, yb(waste_top + 13), "запас / отходы")
    # размеры
    dim_h(c, ix, ix + grid_w, wtop + wh + 14,
          "9 колонок × 50 мм + зазоры 3 мм", color=GREY)
    dim_v(c, wx + ww + 20, yb(itop), yb(itop + grid_h), "5 рядов × 30 мм", color=GREY)
    block(c, M, wtop + wh + 42,
          "Эталон: 50 × 30 мм · N = 5000 · шов сходится по шагу шестерни Z = 96, CP = 3,175.",
          FI, 9.5, 14, 430, GREY)

    # --- крупные цифры ---
    sx, sw_ = 500, W - M - 500
    stats = [
        ("5040", CYAN, "этикеток выдано с загрузкой 9×5 при заказе 5000 шт"),
        ("26,18 %", INK, "отходов полотна на эталонном раскрое при зазоре 3 мм"),
        ("2032,0 мм²", INK, "расход полотна на этикетку — вместе с зазорами и отходами"),
    ]
    tops = [165, 252, 339]
    for (num, col, cap), t in zip(stats, tops):
        c.setFont(FK, 40)
        c.setFillColor(col)
        c.drawString(sx, yb(t), num)
        block(c, sx, t + 24, cap, F, 10.5, 14, sw_, GREY, max_lines=2)
        if t != tops[-1]:
            c.setStrokeColor(RULE)
            c.setLineWidth(0.75)
            c.line(sx, yb(t + 50), sx + sw_, yb(t + 50))
    # главная ценность — крупный тезис
    th_top, bar_h = 392, 96
    c.setFillColor(CYAN)
    c.rect(sx, yb(th_top + bar_h), 4, bar_h, stroke=0, fill=1)
    track(c, sx + 18, th_top + 14, "ГЛАВНАЯ ЦЕННОСТЬ", FB, 9, 1.6, CYAN)
    block(c, sx + 18, th_top + 42,
          "Перебирается и библиотека существующих раппортов цилиндров — "
          "выбирается лучший под ваш тираж.",
          FB, 15.5, 21, sw_ - 18, INK, max_lines=3)


# --------------------------------------------------------------------------
# Слайд 6 — платформы и статус
# --------------------------------------------------------------------------
def slide_status(c):
    c.setFillColor(PAPER)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c)
    chrome(c, "05 · СТАТУС", 6)
    title(c, "Готово и работает")

    # платформы
    platforms = ["iOS", "Windows", "macOS", "Linux", "Web"]
    chip_w, chip_h, gap = 118, 34, 12
    x = M
    for name in platforms:
        card(c, x, 126, chip_w, chip_h, fill=white, stroke=CARD_LINE, r=17)
        c.setFont(FB, 11)
        c.setFillColor(INK)
        c.drawString(x + chip_w / 2 - sw(name, FB, 11) / 2, yb(147), name)
        x += chip_w + gap
    block(c, M, 184,
          "Одно приложение работает на всех пяти платформах — проекты доступны с любого устройства.",
          F, 11, 15, 760, GREY)

    items = [
        ("Точные расчёты",
         "Геометрия, лечение файла, массивы и расход по форме этикетки — проверены на эталонных файлах."),
        ("ТЭО и отчёты",
         "Сортамент, машиночасы, точка безубыточности; отчёты PDF, XLSX и DXF."),
        ("Интерфейс",
         "Понятный русский интерфейс: проекты, раскрой и ТЭО в одном месте."),
        ("Сервисы",
         "Конвертер закрытых форматов, аккаунты и организации, подписка Pro, облачные проекты и файлы."),
        ("Облако и безопасность",
         "Проекты и файлы хранятся в облаке и изолированы по организациям; доступ по защищённому соединению."),
        ("Надёжность",
         "Сквозная проверка сценария от импорта до готового отчёта на реальных файлах."),
    ]
    col_w = (W - 2 * M - 40) / 2
    row_tops = [216, 300, 384]
    for i, (head, body) in enumerate(items):
        x = M + (i // 3) * (col_w + 40)
        y0 = row_tops[i % 3]
        check_badge(c, x + 9, yb(y0 + 6))
        c.setFont(FB, 12)
        c.setFillColor(INK)
        c.drawString(x + 30, yb(y0 + 10), head)
        block(c, x + 30, y0 + 30, body, F, 10.5, 14.5, col_w - 30, GREY, max_lines=3)


# --------------------------------------------------------------------------
# Слайд 7 — заключение (тёмная)
# --------------------------------------------------------------------------
def slide_close(c):
    c.setFillColor(DARK_BG)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c, dark=True)
    track(c, M, 56, "ЗАКЛЮЧЕНИЕ", FB, 9, 1.6, CYAN_LT)
    c.setFont(FB, 34)
    c.setFillColor(white)
    c.drawString(M, yb(120), "Попробуйте на своём тираже")
    block(c, M, 154,
          "Полный набор функций — с первой активации, без карты.",
          F, 13.5, 18, 700, DARK_TEXT)

    cards = [
        ("Триал 15 дней",
         "Полный набор функций на всех платформах: считаете реальные заказы до решения о подписке."),
        ("Free",
         "Один проект и базовый расчёт прямоугольных этикеток."),
        ("Pro",
         "ТЭО, все форматы, отчёты и работа с проектами в облаке."),
        ("Отчёты в один клик",
         "PDF ТЭО для руководства, XLSX для экономиста, DXF для производства."),
    ]
    gap, top, chh = 16, 196, 164
    cw = (W - 2 * M - 3 * gap) / 4
    for i, (head, body) in enumerate(cards):
        x = M + i * (cw + gap)
        card(c, x, top, cw, chh, fill=DARK_CARD, stroke=DARK_LINE)
        c.setFillColor(CYAN_LT)
        c.rect(x + 18, yb(top + 24), 24, 2.5, stroke=0, fill=1)
        y = block(c, x + 18, top + 56, head, FB, 14, 18, cw - 36, white, max_lines=2)
        block(c, x + 18, y + 14, body, F, 10.5, 15, cw - 36, DARK_TEXT, max_lines=5)

    c.setStrokeColor(DARK_LINE)
    c.setLineWidth(0.75)
    c.line(M, yb(420), W - M, yb(420))
    c.setFont(FB, 17)
    c.setFillColor(white)
    c.drawString(M, yb(452), "Препресс-Планер")
    track(c, M, 478, "iOS · WINDOWS · MACOS · LINUX · WEB", FB, 9.5, 1.4, DARK_BODY)
    # приводочная метка справа
    cx, cy, r = W - M - 10, yb(452) + 6, 12
    c.setStrokeColor(CYAN_LT)
    c.setLineWidth(0.9)
    c.circle(cx, cy, r, stroke=1, fill=0)
    c.line(cx - r - 6, cy, cx + r + 6, cy)
    c.line(cx, cy - r - 6, cx, cy + r + 6)


def main():
    register_fonts()
    out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "Препресс-Планер_презентация.pdf")
    c = canvas.Canvas(out, pagesize=(W, H))
    c.setTitle("Препресс-Планер — презентация программы")
    c.setAuthor("Препресс-Планер")
    c.setSubject("Препресс-планирование расходных материалов и ТЭО тиражей этикеток")
    for fn in (slide_cover, slide_problem, slide_pipeline, slide_features,
               slide_calc, slide_status, slide_close):
        fn(c)
        c.showPage()
    c.save()
    print(out)


if __name__ == "__main__":
    main()
