#!/usr/bin/env python3
"""Генератор PDF-руководства «Препресс-Планер»: 20 страниц A4, векторные иллюстрации."""
import os
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, white
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.pagesizes import A4

W, H = A4                       # 595.27 × 841.89
ML = 54
CW = W - 2 * ML                 # ≈ 487.3
TOTAL = 20
SUP = "/System/Library/Fonts/Supplemental"

PAPER = HexColor("#F7F6F2")
INK = HexColor("#101828")
GREY = HexColor("#5B6472")
RULE = HexColor("#D8D5CC")
CYAN = HexColor("#0E7FC0")
CYAN_LT = HexColor("#4DB1E8")
CARD_LINE = HexColor("#E4E1D8")
CELL_HL = HexColor("#D7E9F6")
TIP_BG = HexColor("#EAF3FA")
TIP_LINE = HexColor("#C9DEF0")
DARK_BG = INK
DARK_CARD = HexColor("#1A2434")
DARK_LINE = HexColor("#33405A")
DARK_TEXT = HexColor("#9AA3B2")
DARK_BODY = HexColor("#6B7484")
UI_BG = HexColor("#F2F4F8")
UI_LINE = HexColor("#C8CEDA")
UI_CELL = HexColor("#98A2B3")
SEV_HIGH = HexColor("#C0392B")
SEV_MID = HexColor("#D97706")
SEV_LOW = HexColor("#CA8A04")
HATCH = HexColor("#A8CBE4")

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


def wrap_runs(runs, maxw):
    """runs: [(text, font, size)] → список строк; строка = [(токен, font, size)]."""
    tokens = []
    for text, font, size in runs:
        for part in text.split(" "):
            if part:
                tokens.append((part, font, size))
    lines, cur, cur_w = [], [], 0.0
    for tok, font, size in tokens:
        w = sw(tok, font, size)
        sp = sw(" ", font, size) if cur else 0.0
        if cur and cur_w + sp + w > maxw:
            lines.append(cur)
            cur, cur_w = [(tok, font, size)], w
        else:
            cur.append((tok, font, size))
            cur_w += sp + w
    if cur:
        lines.append(cur)
    return lines


def draw_runs(c, x, base_y, line):
    cx = x
    for tok, font, size in line:
        c.setFont(font, size)
        c.drawString(cx, base_y, tok)
        cx += sw(tok, font, size) + sw(" ", font, size)


def track(c, x, top, text, font, size, tr, color):
    c.setFont(font, size)
    c.setFillColor(color)
    cx, y = x, yb(top)
    for ch in text:
        c.drawString(cx, y, ch)
        cx += sw(ch, font, size) + tr
    return cx


def card(c, x, top, w, h, fill=white, stroke=CARD_LINE, r=6, lw=0.75):
    c.setFillColor(fill)
    c.setStrokeColor(stroke)
    c.setLineWidth(lw)
    c.roundRect(x, yb(top) - h, w, h, r, stroke=1, fill=1)


def hatch(c, x, y, w, h, step=8, color=HATCH, lw=0.6):
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


def crop_marks(c, dark=False):
    col = DARK_LINE if dark else RULE
    c.setStrokeColor(col)
    c.setLineWidth(0.8)
    i, arm = 20, 12
    c.line(i, H - i, i, H - i - arm)
    c.line(i, H - i, i + arm, H - i)
    c.line(W - i, H - i, W - i, H - i - arm)
    c.line(W - i, H - i, W - i - arm, H - i)
    c.line(i, i, i, i + arm)
    c.line(i, i, i + arm, i)
    c.line(W - i, i, W - i, i + arm)
    c.line(W - i, i, W - i - arm, i)


def crosshair(c, cx, cy, r=5, color=CYAN):
    c.setStrokeColor(color)
    c.setLineWidth(0.7)
    c.circle(cx, cy, r, stroke=1, fill=0)
    c.line(cx - r - 4, cy, cx + r + 4, cy)
    c.line(cx, cy - r - 4, cx, cy + r + 4)


def page_chrome(c, num, kicker=None, dark=False):
    foot_col = DARK_BODY if dark else GREY
    rule_col = DARK_LINE if dark else RULE
    if kicker:
        track(c, ML, 44, kicker, FB, 8.5, 1.6, CYAN_LT if dark else CYAN)
    c.setStrokeColor(rule_col)
    c.setLineWidth(0.75)
    c.line(ML, yb(800), W - ML, yb(800))
    c.setFont(F, 8)
    c.setFillColor(foot_col)
    c.drawString(ML, yb(816), "Препресс-Планер · руководство пользователя")
    c.setFont(FB, 8)
    c.drawRightString(W - ML, yb(816), f"{num:02d} / {TOTAL:02d}")


def page_head(c, kicker, title, intro=None, title_size=21, intro_size=10.5):
    """Возвращает top содержимого после шапки."""
    c.setFillColor(PAPER)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c)
    page_chrome(c, page_head.num, kicker)
    c.setFont(FB, title_size)
    c.setFillColor(INK)
    c.drawString(ML, yb(74), title)
    top = 94
    if intro:
        top = block(c, ML, top, intro, F, intro_size, 14.5, CW - 10, GREY) + 8
    return top


page_head.num = 0


# ==========================================================================
# Примитивы схем интерфейса
# ==========================================================================
def ui_badge(c, cx, top, n, r=7.5, color=CYAN):
    c.setFillColor(color)
    c.setStrokeColor(white)
    c.setLineWidth(1.2)
    c.circle(cx, yb(top), r, stroke=1, fill=1)
    c.setFillColor(white)
    c.setFont(FB, 8)
    s = str(n)
    c.drawString(cx - sw(s, FB, 8) / 2, yb(top) - 2.9, s)


def ui_btn(c, x, top, label, primary=False, h=15, size=7.5, w=None):
    tw = sw(label, FB, size)
    bw = w if w else tw + 14
    c.setFillColor(CYAN if primary else white)
    c.setStrokeColor(CYAN if primary else UI_LINE)
    c.setLineWidth(0.8)
    c.roundRect(x, yb(top) - h, bw, h, 4, stroke=1, fill=1)
    c.setFillColor(white if primary else INK)
    c.setFont(FB, size)
    c.drawString(x + (bw - tw) / 2, yb(top) - h + (h - size * 0.95) / 2 + 1, label)
    return bw


def ui_input(c, x, top, w, text, h=15, size=8, muted=False):
    c.setFillColor(white)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.8)
    c.roundRect(x, yb(top) - h, w, h, 3, stroke=1, fill=1)
    c.setFillColor(GREY if muted else INK)
    c.setFont(F, size)
    c.drawString(x + 6, yb(top) - h + (h - size * 0.95) / 2 + 1, text)
    return h


def ui_field(c, x, top, w, label, value, size=7.5, h=14):
    """Подпись + поле ввода. Возвращает занятую высоту."""
    c.setFillColor(GREY)
    c.setFont(FB, size)
    c.drawString(x, yb(top), label)
    ui_input(c, x, top + 5, w, value, h=h, size=8.5)
    return 5 + h + 4


def ui_dropdown(c, x, top, w, label, value, h=14, size=7.5):
    c.setFillColor(GREY)
    c.setFont(FB, size)
    c.drawString(x, yb(top), label)
    iy = top + 5
    c.setFillColor(white)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.8)
    c.roundRect(x, yb(iy) - h, w, h, 3, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 8)
    c.drawString(x + 6, yb(iy) - h + (h - 7) / 2 + 1, value)
    c.setFillColor(GREY)
    c.setFont(FB, 7)
    c.drawString(x + w - 12, yb(iy) - h + (h - 7) / 2 + 1, "▾")
    return 5 + h + 4


def ui_status(c, x, top, text, color=GREY, size=7.5, font=None):
    c.setFillColor(color)
    c.setFont(font or F, size)
    c.drawString(x, yb(top), text)


def ui_check(c, cx, cy, r=6, color=CYAN):
    c.setFillColor(color)
    c.setStrokeColor(color)
    c.circle(cx, cy, r, stroke=0, fill=1)
    c.setStrokeColor(white)
    c.setLineWidth(1.4)
    p = c.beginPath()
    p.moveTo(cx - r * 0.45, cy)
    p.lineTo(cx - r * 0.12, cy - r * 0.38)
    p.lineTo(cx + r * 0.45, cy + r * 0.38)
    c.drawPath(p, stroke=1, fill=0)


def ui_chip(c, x, top, label, active=False, h=13, size=7):
    tw = sw(label, FB, size)
    w = tw + 12
    c.setFillColor(CYAN if active else UI_BG)
    c.setStrokeColor(CYAN if active else UI_LINE)
    c.setLineWidth(0.7)
    c.roundRect(x, yb(top) - h, w, h, h / 2, stroke=1, fill=1)
    c.setFillColor(white if active else INK)
    c.setFont(FB, size)
    c.drawString(x + 6, yb(top) - h + (h - size * 0.95) / 2 + 1, label)
    return w


def ui_issue(c, x, top, w, sev_color, msg, fix="Исправить", h=16):
    """Строка ошибки: точка severity, сообщение, кнопка."""
    c.setFillColor(white)
    c.setStrokeColor(CARD_LINE)
    c.setLineWidth(0.7)
    c.roundRect(x, yb(top) - h, w, h, 3, stroke=1, fill=1)
    c.setFillColor(sev_color)
    c.circle(x + 8, yb(top) - h / 2, 3, stroke=0, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 7.5)
    c.drawString(x + 16, yb(top) - h + 4.5, msg)
    bw = sw(fix, FB, 7) + 12
    ui_btn(c, x + w - bw - 4, top - h + 2.5, fix, primary=True, h=h - 5, size=7, w=bw)
    return h + 4


def ui_table(c, x, top, w, headers, rows, col_ratios=None, row_h=14, size=7.5,
             hi_row=None, align_center_from=1):
    n = len(headers)
    if col_ratios is None:
        col_ratios = [1.0 / n] * n
    total = sum(col_ratios)
    widths = [w * r / total for r in col_ratios]
    xs = [x]
    for cw_ in widths[:-1]:
        xs.append(xs[-1] + cw_)
    hh = row_h + 2
    # шапка
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.rect(x, yb(top) - hh, w, hh, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, size)
    for i, htxt in enumerate(headers):
        tx = xs[i] + widths[i] / 2 if i >= align_center_from else xs[i] + 5
        c.drawCentredString(tx, yb(top) - row_h + 1, htxt) if i >= align_center_from \
            else c.drawString(tx, yb(top) - row_h + 1, htxt)
    yy = top + hh
    for r_i, row in enumerate(rows):
        fill = CELL_HL if r_i == hi_row else white
        c.setFillColor(fill)
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.6)
        c.rect(x, yb(yy), w, row_h, stroke=1, fill=1)
        c.setFillColor(INK)
        c.setFont(FB if r_i == hi_row else F, size)
        for i, cell in enumerate(row):
            tx = xs[i] + widths[i] / 2 if i >= align_center_from else xs[i] + 5
            if i >= align_center_from:
                c.drawCentredString(tx, yb(yy) - row_h + 4.5, str(cell))
            else:
                c.drawString(tx, yb(yy) - row_h + 4.5, str(cell))
        yy += row_h
    return yy - top


def ui_label_cell(c, x, top, w, h, mode="copy"):
    if mode == "master":
        c.setFillColor(HexColor("#EAF6FC"))
        c.setStrokeColor(CYAN)
        lw = 1.3
    elif mode == "healed":
        c.setFillColor(white)
        c.setStrokeColor(INK)
        lw = 0.9
    else:
        c.setFillColor(white)
        c.setStrokeColor(UI_CELL)
        lw = 0.7
    c.setLineWidth(lw)
    c.roundRect(x, yb(top) - h, w, h, 2, stroke=1, fill=1)


def ui_canvas(c, x, top, w, h, cols=5, rows=3, master_rc=None, markers=None,
              healed=False, label_w=34, label_h=20, gap=5):
    """Область холста с сеткой этикеток и маркерами ошибок."""
    c.setFillColor(HexColor("#FAFAF7"))
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.8)
    c.rect(x, yb(top) - h, w, h, stroke=1, fill=1)
    grid_w = cols * label_w + (cols - 1) * gap
    grid_h = rows * label_h + (rows - 1) * gap
    ox = x + (w - grid_w) / 2
    oy = top + (h - grid_h) / 2
    for r in range(rows):
        for k in range(cols):
            cx = ox + k * (label_w + gap)
            cy = oy + r * (label_h + gap)
            mode = "copy"
            if master_rc == (r, k):
                mode = "master"
            elif healed:
                mode = "healed"
            ui_label_cell(c, cx, cy, label_w, label_h, mode=mode)
    if markers:
        for (mx, my, col) in markers:
            c.setFillColor(col)
            c.setStrokeColor(white)
            c.setLineWidth(1)
            c.circle(x + mx * w, yb(top + my * h), 4.5, stroke=1, fill=1)


def ui_slider(c, x, top, w, label, value_txt, frac=0.5, size=7.5):
    c.setFillColor(GREY)
    c.setFont(FB, size)
    c.drawString(x, yb(top), label)
    c.setFillColor(INK)
    c.setFont(FB, 8)
    c.drawRightString(x + w, yb(top), value_txt)
    ty = top + 9
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(3)
    c.line(x, yb(ty), x + w, yb(ty))
    c.setStrokeColor(CYAN)
    c.setLineWidth(3)
    c.line(x, yb(ty), x + w * frac, yb(ty))
    c.setFillColor(white)
    c.setStrokeColor(CYAN)
    c.setLineWidth(1.4)
    c.circle(x + w * frac, yb(ty), 5, stroke=1, fill=1)
    return 16


# ==========================================================================
# Контент-примитивы страниц
# ==========================================================================
def steps_list(c, x, top, items, maxw, gap=9, lead_size=10, body_size=9.5,
               leading=13, r=7.5):
    """Нумерованные шаги: кружок как в выносках иллюстрации + заголовок + текст."""
    tx = x + 2 * r + 11
    for i, (lead, body) in enumerate(items, 1):
        c.setFillColor(CYAN)
        c.setStrokeColor(CYAN)
        c.circle(x + r, yb(top + r), r, stroke=0, fill=1)
        c.setFillColor(white)
        c.setFont(FB, 8.5)
        s = str(i)
        c.drawString(x + r - sw(s, FB, 8.5) / 2, yb(top + r) - 3, s)
        c.setFont(FB, lead_size)
        c.setFillColor(INK)
        c.drawString(tx, yb(top + lead_size + 1), lead)
        y = block(c, tx, top + lead_size + 4 + leading, body, F, body_size,
                  leading, maxw - (tx - x), GREY)
        top = y + gap
    return top - gap


def note(c, top, kind, text, maxw=CW):
    """Врезка: kind = 'tip' | 'warn'."""
    if kind == "tip":
        bg, bar, lab = TIP_BG, CYAN, CYAN
        label = "СОВЕТ"
    else:
        bg, bar, lab = HexColor("#FDECEA"), SEV_HIGH, SEV_HIGH
        label = "ВНИМАНИЕ"
    pad = 12
    c.setFont(FB, 8)
    lab_w = sw(label, FB, 8)
    lines = wrap(text, F, 9.5, maxw - pad * 2)
    h = 14 + len(lines) * 13 + 10
    c.setFillColor(bg)
    c.setStrokeColor(bar)
    c.setLineWidth(0.6)
    c.roundRect(ML, yb(top) - h, maxw, h, 5, stroke=1, fill=1)
    c.setFillColor(bar)
    c.rect(ML, yb(top) - h, 3.5, h, stroke=0, fill=1)
    c.setFont(FB, 8)
    c.setFillColor(lab)
    c.drawString(ML + pad, yb(top + 16), label)
    c.setFillColor(INK)
    c.setFont(F, 9.5)
    yy = top + 30
    for ln in lines:
        c.drawString(ML + pad, yb(yy), ln)
        yy += 13
    return top + h


def fig_frame(c, top, h, title=None):
    """Белая рамка иллюстрации. Возвращает внутренний top содержимого."""
    card(c, ML, top, CW, h, fill=white, stroke=CARD_LINE, r=8, lw=0.9)
    if title:
        c.setFont(FB, 8.5)
        c.setFillColor(GREY)
        c.drawString(ML + 14, yb(top + 15), title)
        return top + 26
    return top + 14


def fig_cap(c, top, text):
    block(c, ML, top, text, FI, 8.5, 12, CW, GREY)
    return top + 12 * len(wrap(text, FI, 8.5, CW)) + 4


def legend_row(c, x, top, items, size=8):
    """Горизонтальная легенда выносок: ① текст · ② текст · …"""
    cx = x
    for i, txt in enumerate(items, 1):
        c.setFillColor(CYAN)
        c.circle(cx + 5, yb(top + 5), 5, stroke=0, fill=1)
        c.setFillColor(white)
        c.setFont(FB, 6.5)
        s = str(i)
        c.drawString(cx + 5 - sw(s, FB, 6.5) / 2, yb(top + 5) - 2.2, s)
        c.setFillColor(GREY)
        c.setFont(F, size)
        c.drawString(cx + 14, yb(top + 8), txt)
        cx += 14 + sw(txt, F, size) + 16
        if cx > ML + CW - 60 and i < len(items):
            return top + 18, i   # перенос не поддерживаем — caller разбивает сам
    return top + 16, len(items)


# ==========================================================================
# Страница 2 — оглавление
# ==========================================================================
def page_toc(c):
    top = page_head(
        c, "НАЧАЛО РАБОТЫ",
        "Как пользоваться инструкцией",
        "Каждая операция разобрана по шагам: схема экрана с выносками, порядок "
        "действий и пояснения. Номера на схеме совпадают с номерами шагов.")
    # легенда обозначений
    h = 104
    y = fig_frame(c, top, h, "ОБОЗНАЧЕНИЯ")
    lx = ML + 14
    c.setFillColor(CYAN)
    c.circle(lx + 6, yb(y + 6), 6.5, stroke=0, fill=1)
    c.setFillColor(white)
    c.setFont(FB, 8)
    c.drawString(lx + 3.5, yb(y + 6) - 3, "1")
    c.setFillColor(INK)
    c.setFont(F, 9.5)
    c.drawString(lx + 20, yb(y + 9), "— номер шага: совпадает на схеме и в тексте операции")
    y2 = y + 24
    c.setFillColor(TIP_BG)
    c.setStrokeColor(CYAN)
    c.setLineWidth(0.6)
    c.roundRect(lx, yb(y2) - 14, 14, 14, 3, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 9.5)
    c.drawString(lx + 20, yb(y2 + 11), "— блок «СОВЕТ»: как ускорить или упростить работу")
    y3 = y2 + 26
    c.setFillColor(HexColor("#FDECEA"))
    c.setStrokeColor(SEV_HIGH)
    c.setLineWidth(0.6)
    c.roundRect(lx, yb(y3) - 14, 14, 14, 3, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 9.5)
    c.drawString(lx + 20, yb(y3 + 11), "— блок «ВНИМАНИЕ»: типичная ошибка и её последствия")
    # собственно оглавление
    top = top + h + 16
    track(c, ML, top, "СОДЕРЖАНИЕ", FB, 8.5, 1.6, CYAN)
    top += 14
    entries = [
        ("Обзор интерфейса", 3),
        ("Операция 1. Проекты: создать и открыть", 4),
        ("Операция 2. Импорт векторного файла", 5),
        ("Операция 3. Диагностика и лечение", 6),
        ("Операция 4. Распознавание массива", 7),
        ("Операция 5. Ширина материала и сетка", 8),
        ("Операция 6. Параметры раскроя и расчёт", 9),
        ("Операция 7. Перебор вариантов раскроя", 10),
        ("Операция 8. Рейтинг по магнитным валам", 11),
        ("Операция 9. Расчёт ТЭО", 12),
        ("Операция 10. Чувствительность цены", 13),
        ("Операция 11. Отчёты PDF, XLSX, DXF", 14),
        ("Операция 12. Аккаунт, подписка, организация", 15),
        ("Сквозной сценарий: файл → отчёт", 16),
        ("Частые ошибки и сообщения", 17),
        ("Справка: параметры и формулы", 18),
        ("Журнал событий и советы", 19),
        ("Быстрый старт: чек-лист", 20),
    ]
    col_w = (CW - 30) / 2
    for i, (name, pg) in enumerate(entries):
        col, row = i // 9, i % 9
        x = ML + col * (col_w + 30)
        yy = top + row * 22
        size = 10 if sw(name, F, 10) <= col_w - 24 else 9
        c.setFillColor(INK)
        c.setFont(F, size)
        c.drawString(x, yb(yy + 10), name)
        c.setStrokeColor(RULE)
        c.setLineWidth(0.5)
        c.line(x + sw(name, F, 10) + 6, yb(yy + 7),
               x + col_w - 16, yb(yy + 7))
        c.setFillColor(CYAN)
        c.setFont(FB, 10)
        c.drawRightString(x + col_w, yb(yy + 10), str(pg))


# ==========================================================================
# Страница 3 — обзор интерфейса
# ==========================================================================
def page_overview(c):
    top = page_head(
        c, "ОБЗОР",
        "Интерфейс: одна лента, пять разделов",
        "Программа состоит из шапки, панели разделов и рабочей области. "
        "Проект ведёт вас слева направо: от импорта файла до готовых отчётов.")
    h = 240
    y = fig_frame(c, top, h, "ОКНО ПРОГРАММЫ")
    ix, iw = ML + 14, CW - 28
    # шапка окна
    bar_h = 26
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.8)
    c.rect(ix, yb(y) - bar_h, iw, bar_h, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(ix + 10, yb(y) - 17, "Этикетка_50x30 — Препресс-Планер")
    # иконка журнала с бейджем
    jx = ix + iw - 150
    c.setStrokeColor(GREY)
    c.setLineWidth(0.9)
    c.rect(jx, yb(y) - 18, 12, 12, stroke=1, fill=0)
    c.line(jx + 3, yb(y) - 14, jx + 9, yb(y) - 14)
    c.line(jx + 3, yb(y) - 11, jx + 9, yb(y) - 11)
    c.setFillColor(SEV_HIGH)
    c.circle(jx + 12, yb(y) - 6, 4.5, stroke=0, fill=1)
    c.setFillColor(white)
    c.setFont(FB, 5.5)
    c.drawString(jx + 10.3, yb(y) - 7.7, "3")
    # кнопка аккаунта
    aw = ui_btn(c, ix + iw - 120, y + 6, "Войти", primary=False, h=15, size=7.5)
    # чип подписки
    ui_chip(c, ix + iw - 46, y + 6.5, "Free", active=True, h=14, size=7)
    # панель разделов (лево)
    rail_w = 96
    rail_h = h - 26 - 28
    ry = y + bar_h
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.rect(ix, yb(ry) - rail_h, rail_w, rail_h, stroke=1, fill=1)
    tabs = ["Проекты", "Геометрия", "Раскрой", "ТЭО", "Отчёты"]
    active = 2
    for i, t in enumerate(tabs):
        ty = ry + 8 + i * 24
        if i == active:
            c.setFillColor(CELL_HL)
            c.roundRect(ix + 5, yb(ty) - 18, rail_w - 10, 18, 4, stroke=0, fill=1)
            c.setFillColor(CYAN)
            c.rect(ix + 5, yb(ty) - 18, 2.5, 18, stroke=0, fill=1)
        c.setFillColor(INK if i == active else GREY)
        c.setFont(FB if i == active else F, 8.5)
        c.drawString(ix + 14, yb(ty) - 13, t)
    # рабочая область — набросок формы параметров
    wx = ix + rail_w + 10
    ww = iw - rail_w - 10
    c.setStrokeColor(CARD_LINE)
    c.setLineWidth(0.7)
    c.roundRect(wx, yb(ry) - rail_h, ww, rail_h, 4, stroke=1, fill=0)
    c.setFillColor(GREY)
    c.setFont(FB, 8)
    c.drawString(wx + 12, yb(ry + 14), "РАБОЧАЯ ОБЛАСТЬ")
    # мок-поля
    for i in range(3):
        fy = ry + 30 + i * 30
        ui_field(c, wx + 12, fy, 84, ["Этикетка W, мм", "Зазор X, мм", "Зубья Z"][i],
                 ["50", "3", "96"][i])
        ui_field(c, wx + 106, fy, 84, ["Этикетка H, мм", "Зазор Y, мм", "Шаг CP, мм"][i],
                 ["30", "3", "3,175"][i])
        ui_field(c, wx + 200, fy, 84, ["Полотно, мм", "Мин. зазор, мм", "Кол-во N"][i],
                 ["300", "3", "5000"][i])
    ui_btn(c, wx + 296, ry + 36, "Рассчитать", primary=True, h=16, size=8, w=74)
    # футер статуса
    fy = ry + rail_h - 22
    c.setStrokeColor(UI_LINE)
    c.line(ix, yb(fy), ix + iw, yb(fy))
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(ix + 10, yb(fy + 14), "Готово · автосохранение включено")
    c.drawRightString(ix + iw - 10, yb(fy + 14), "© 2026 Препресс-Планер")
    # выноски
    ui_badge(c, ix + 160, y + 13, 1)                       # шапка
    ui_badge(c, jx + 24, y + 10, 2)                        # журнал
    ui_badge(c, ix + iw - 128, y + 13.5, 3)                # аккаунт
    ui_badge(c, ix + iw - 30, y + 13.5, 4)                 # подписка
    ui_badge(c, ix + rail_w / 2, ry + rail_h - 14, 5)      # разделы
    ui_badge(c, wx + ww - 16, ry + rail_h - 16, 6)         # область
    top = top + h + 6
    top = fig_cap(c, top, "Схема: шапка, панель разделов и рабочая область. "
                          "Выноски соответствуют пояснениям ниже.")
    items = [
        ("Шапка", "Имя открытого проекта, иконка журнала, кнопка аккаунта и чип подписки "
                  "(Free / Триал / Pro)."),
        ("Журнал событий", "Значок с красным счётчиком — число ошибок. Открывается кликом: "
                           "все сообщения можно копировать."),
        ("Аккаунт", "Вход по email и пароль; в вошедшем режиме здесь отображается ваш адрес."),
        ("Подписка", "Клик по чипу открывает окно Pro с тарифами и статусом триала."),
        ("Разделы", "Пять вкладок: Проекты → Геометрия → Раскрой → ТЭО → Отчёты. "
                    "Порядок повторяет рабочий процесс."),
        ("Рабочая область", "Формы, холст с геометрией и таблицы. Всё, что вы меняете, "
                            "сохраняется в проект автоматически."),
    ]
    top += 6
    top = steps_list(c, ML, top, items, CW, gap=7, lead_size=9.5, body_size=9, leading=12)


# ==========================================================================
# Операции 1–6
# ==========================================================================
def page_op1_projects(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 01 · ПРОЕКТЫ",
        "Создать и открыть проект",
        "Проект — контейнер всего расчёта: исходный файл, параметры, лечение "
        "геометрии, раскрой, ТЭО и отчёты. Без открытого проекта остальные "
        "разделы показывают подсказку «Создайте или откройте проект».")
    h = 150
    y = fig_frame(c, top, h, "РАЗДЕЛ «ПРОЕКТЫ»")
    ix, iw = ML + 14, CW - 28
    # строка создания
    c.setFont(FB, 7.5)
    c.setFillColor(GREY)
    c.drawString(ix, yb(y + 4), "Имя проекта")
    ui_input(c, ix, y + 9, 210, "Этикетка_50x30", h=16, size=8.5)
    ui_btn(c, ix + 218, y + 10.5, "Создать", primary=True, h=14, size=8)
    # карточки проектов
    cy = y + 42
    for i, (name, sub, opened) in enumerate([
        ("Этикетка_50x30", "открыт", True),
        ("Этикетка_ылтым", "двойной клик — открыть", False),
    ]):
        cx = ix + i * 240
        c.setFillColor(CELL_HL if opened else white)
        c.setStrokeColor(CYAN if opened else CARD_LINE)
        c.setLineWidth(1 if opened else 0.7)
        c.roundRect(cx, yb(cy) - 52, 226, 52, 6, stroke=1, fill=1)
        # иконка папки
        c.setFillColor(CYAN if opened else GREY)
        c.roundRect(cx + 12, yb(cy) - 34, 22, 17, 2, stroke=0, fill=1)
        c.roundRect(cx + 12, yb(cy) - 20, 22, 5, 1, stroke=0, fill=1)
        c.setFillColor(INK)
        c.setFont(FB, 9)
        c.drawString(cx + 44, yb(cy) - 22, name)
        c.setFillColor(GREY if not opened else CYAN)
        c.setFont(F, 7.5)
        c.drawString(cx + 44, yb(cy) - 36, sub)
    ui_badge(c, ix + 292, y + 17, 1)
    ui_badge(c, ix + 14, cy + 10, 2)
    ui_badge(c, ix + 254, cy + 10, 3)
    top = top + h + 6
    top = fig_cap(c, top, "Схема раздела «Проекты»: строка создания и список проектов.")
    steps = [
        ("Откройте раздел «Проекты»",
         "Первый пункт панели слева. Здесь видны все проекты: в вебе — облачные "
         "при активной сессии, на десктопе — локальные."),
        ("Введите имя и нажмите «Создать»",
         "По умолчанию предлагается «Новый проект». Если имя занято, появится "
         "сообщение «Проект уже существует — выберите другое имя»."),
        ("Откройте проект кликом по карточке",
         "Карточка открытого проекта подсвечена и помечена «открыт». Программа "
         "сразу переходит на вкладку «Геометрия» — можно импортировать файл."),
        ("Возвращайтесь к другим проектам",
         "Имя открытого проекта видно в шапке окна. Переключение между "
         "проектами — повторным кликом по карточке."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "warn",
               "В Free-режиме доступен один проект: создание второго откроет шторку "
               "«Второй проект доступен в Pro (Free — 1 проект)». Проекты сохраняются "
               "автоматически при каждом изменении — отдельная кнопка «Сохранить» не нужна.")


def page_op2_import(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 02 · ГЕОМЕТРИЯ",
        "Импортировать векторный файл",
        "Поддерживаются DXF, SVG, PDF (разбираются локально) и AI, CDR, EPS "
        "(конвертируются на сервере в SVG). Результат импорта — контуры на холсте "
        "и отчёт «Загружено контуров: N; ошибок: M».")
    h = 176
    y = fig_frame(c, top, h, "ВЕРХНЯЯ ПАНЕЛЬ РАЗДЕЛА «ГЕОМЕТРИЯ»")
    ix, iw = ML + 14, CW - 28
    # строка пути
    c.setFont(FB, 7.5)
    c.setFillColor(GREY)
    c.drawString(ix, yb(y + 4), "Путь к файлу (DXF/SVG/PDF/AI/CDR/EPS)")
    ui_input(c, ix, y + 9, 200, "/Заказчики/этикетка_сырья.dxf", h=16, size=8)
    ui_badge(c, ix + 210, y + 17, 1)
    ui_btn(c, ix + 226, y + 10.5, "Обзор…", h=14, size=8)
    ui_badge(c, ix + 284, y + 17, 2)
    ui_btn(c, ix + 300, y + 10.5, "Импорт", primary=True, h=14, size=8)
    ui_badge(c, ix + 360, y + 17, 3)
    c.setFillColor(GREY)
    c.setFont(FI, 7)
    c.drawString(ix, yb(y + 32), "AI/CDR/EPS конвертируются автоматически")
    # статусы
    sy = y + 44
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(sy) - 22, iw - 130, 22, 4, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 8)
    c.drawString(ix + 8, yb(sy) - 14.5, "Загружено контуров: 128; ошибок: 3.")
    # сервер конвертации
    sx = ix + iw - 122
    ui_btn(c, sx, sy - 19, "Запустить сервер", h=14, size=7.5, w=88)
    ui_check(c, sx + 104, yb(sy - 12), r=6)
    ui_badge(c, sx + 118, sy - 12, 4)
    # холст с контурами
    cy = sy + 32
    ui_canvas(c, ix, cy, iw, 66, cols=5, rows=2,
              master_rc=None, markers=[(0.22, 0.35, SEV_HIGH),
                                       (0.68, 0.6, SEV_MID),
                                       (0.85, 0.3, SEV_LOW)],
              label_w=54, label_h=24, gap=7)
    ui_badge(c, ix + iw - 18, cy + 18, 5)
    top = top + h + 6
    top = fig_cap(c, top, "Схема панели импорта: путь, кнопки, сводка, сервер "
                          "конвертации и холст с маркерами ошибок.")
    steps = [
        ("Укажите файл",
         "Кнопка «Обзор…» открывает диалог выбора векторного файла (DXF, SVG, PDF, "
         "AI, CDR, EPS); путь можно и вписать вручную. В вебе — кнопка «Импорт файла»."),
        ("Нажмите «Импорт»",
         "Идут статусы «Чтение файла…» → «Разбор файла…» → «Анализ "
         "технологичности…». Внизу появится сводка: сколько контуров загружено и сколько ошибок."),
        ("Для AI/CDR/EPS запустите сервер",
         "Кнопка «Запустить сервер» поднимает локальный конвертер; зелёная галочка "
         "«Сервер работает» означает, что закрытые форматы доступны."),
        ("Оцените холст",
         "Колесо мыши — зум, перетаскивание — панорама. Цветные маркеры — места "
         "с ошибками геометрии; полный список — в блоке «Ошибки технологичности»."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "tip",
               "Если разбор идёт дольше 90 секунд, файл слишком сложный или повреждён — "
               "упростите его в редакторе или пересохраните в DXF/SVG. Файл не найден — "
               "проверьте путь; ошибка конвертации — убедитесь, что сервер запущен и доступен сеть.")


def page_op3_diagnose(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 03 · ГЕОМЕТРИЯ",
        "Диагностика и лечение геометрии",
        "После импорта программа сама находит разрывы, пересечения, дубликаты, "
        "«пыль» и острые углы. Каждой проблеме соответствует рекомендация и кнопка "
        "«Исправить» — лечение выполняется в один клик.")
    h = 190
    y = fig_frame(c, top, h, "СПИСОК «ОШИБКИ ТЕХНОЛОГИЧНОСТИ»")
    ix, iw = ML + 14, CW - 28
    # слева — холст с маркером
    ui_canvas(c, ix, y, 190, h - 44, cols=3, rows=3, master_rc=None,
              markers=[(0.3, 0.3, SEV_HIGH), (0.7, 0.62, SEV_MID),
                       (0.55, 0.8, SEV_LOW)],
              label_w=42, label_h=24, gap=6)
    # справа — список ошибок
    lx = ix + 204
    lw = iw - 204
    c.setFillColor(INK)
    c.setFont(FB, 9)
    c.drawString(lx, yb(y + 4), "Ошибки технологичности")
    ey = y + 14
    for sev, msg in [
        (SEV_HIGH, "Разрыв контура 0,18 мм на (12,4; 30,0)"),
        (SEV_MID, "Самопересечение в точке (88,1; 15,2)"),
        (SEV_LOW, "Дубликат линии, 2 совпадения"),
    ]:
        ey = ui_issue(c, lx, ey, lw, sev, msg) + 2
    ui_btn(c, lx, ey + 2, "Исправить всё", primary=False, h=15, size=7.5)
    # выноски
    ui_badge(c, ix + 60, y + h - 60, 1)
    ui_badge(c, lx + lw - 30, y + 40, 2)
    ui_badge(c, lx + 40, ey + 10, 3)
    top = top + h + 6
    top = fig_cap(c, top, "Схема: маркеры на холсте (1) ↔ строки списка с рекомендациями "
                          "(2) и кнопки исправления (3).")
    steps = [
        ("Прочитайте проблему",
         "Каждая строка содержит сообщение (цвет точки — важность: красный, оранжевый, "
         "жёлтый) и рекомендацию, что именно не так."),
        ("Нажмите «Исправить» в строке",
         "Программа лечит контур: замыкает разрывы, убирает пересечения и дубликаты, "
         "удаляет «пыль». Статус «Применение исправления…» сменяется на «Исправление применено»."),
        ("Проверьте результат на холсте",
         "Маркер исчезает. Если ошибок много — правьте по порядку сверху вниз: сначала "
         "красные (блокирующие), затем оранжевые и жёлтые."),
        ("При распознанном массиве лечится мастер",
         "В режиме массива исправление применяется к мастер-элементу, затем массив "
         "пересобирается: «Исправление применено к мастеру… Массив пересобран»."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "tip",
               "Пустой список — «Ошибок не найдено» — означает, что файл технологичен. "
               "Список обновляется после каждого импорта и каждого исправления; все "
               "действия попадают в журнал событий (иконка в шапке).")


def page_op4_array(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 04 · ГЕОМЕТРИЯ",
        "Распознать массив этикеток",
        "Кнопка «Распознать массив» находит в файле мастер-элемент и закон его "
        "повторения (ряды × колонки, шаг, зазоры), вылечивает только мастер и "
        "размножает его по закону на слой ARRAY. Размеры этикетки автоматически "
        "попадают в параметры раскроя.")
    h = 176
    y = fig_frame(c, top, h, "ОПЕРАЦИИ МАССИВА")
    ix, iw = ML + 14, CW - 28
    # чипы операций
    w1 = ui_chip(c, ix, y + 2, "Распознать массив", active=True, h=17, size=8.5)
    ui_chip(c, ix + w1 + 8, y + 2, "Сгенерировать сетку", active=False, h=17, size=8.5)
    # статус
    stx = ix + w1 + 8 + 118 + 12
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(stx, yb(y + 14), "Массив: 5×9 (45 копий), этикетка 50×30 мм, шаг 53×33 мм.")
    # холст: мастер + копии
    cy = y + 34
    ui_canvas(c, ix, cy, iw, 84, cols=9, rows=5, master_rc=(2, 4),
              markers=None, label_w=38, label_h=12, gap=4)
    # пояснительная строка
    ly = cy + 94
    c.setFont(F, 7.5)
    c.setFillColor(GREY)
    c.drawString(ix, yb(ly), "бирюзовый — мастер (MASTER) · индигово — копии (ARRAY) · "
                             "размеры уже подставлены в «Раскрой»")
    # блок «ширина материала» — превью следующей операции
    wy = ly + 12
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(wy) - 34, iw, 34, 4, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, 8)
    c.drawString(ix + 10, yb(wy) - 14, "Ширина материала")
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(ix + 10, yb(wy) - 27, "Макет: 465 мм · Рекомендуемая ширина: 475 мм")
    ui_btn(c, ix + iw - 148, wy - 28, "Применить к раскрою (полотно)", primary=True,
           h=14, size=7.5, w=140)
    ui_badge(c, ix + 56, y + 11, 1)
    ui_badge(c, ix + 178, y + 11, 2)
    ui_badge(c, ix + iw - 20, cy + 44, 3)
    ui_badge(c, ix + iw - 16, wy - 17, 4)
    top = top + h + 6
    top = fig_cap(c, top, "Схема операций массива: чипы, итог распознавания, холст "
                          "с мастером и блок ширины материала.")
    steps = [
        ("Нажмите «Распознать массив»",
         "Идут стадии: «Распознавание массива…» → «Лечение мастер-элемента…» → "
         "«Анализ мастер-элемента…» → «Размножение по закону…»."),
        ("Прочитайте итог",
         "В статусе: сколько рядов и колонок, число копий, размер этикетки и шаг. "
         "Эти значения сразу записываются в параметры раскроя."),
        ("При необходимости пересоберите сетку",
         "Кнопка «Сгенерировать сетку» перестраивает массив из вылеченного мастера — "
         "используйте её, если после распознавания меняли параметры раскроя."),
        ("Примените ширину материала",
         "Блок «Ширина материала» рассчитывает рекомендуемую ширину полотна "
         "(макет + поля) и кнопкой «Применить к раскрою (полотно)» передаёт её в расчёт."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "warn",
               "«Массив не найден» — файл содержит одиночный контур, размножать нечего: "
               "тогда стройте сетку вручную на вкладке «Раскрой». «Не удалось вылечить "
               "мастер» — сначала исправьте ошибки геометрии (операция 3) и повторите.")


def page_op5_width(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 05 · ГЕОМЕТРИЯ",
        "Ширина материала и генерация сетки",
        "После распознавания массива появляется блок «Ширина материала»: он "
        "считает, сколько полотна занимает макет с полями, и передаёт ширину "
        "в параметры раскроя.")
    h = 170
    y = fig_frame(c, top, h, "БЛОК «ШИРИНА МАТЕРИАЛА»")
    ix, iw = ML + 14, CW - 28
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(ix, yb(y + 6), "Ширина материала")
    c.setFillColor(GREY)
    c.setFont(F, 8.5)
    c.drawString(ix, yb(y + 22), "Макет (крайний левый ↔ крайний правый элемент): 465 мм")
    # схема полотна
    sy = y + 34
    sh = 54
    c.setFillColor(white)
    c.setStrokeColor(INK)
    c.setLineWidth(1)
    c.rect(ix, yb(sy) - sh, iw, sh, stroke=1, fill=1)
    # поля заштрихованы
    hatch(c, ix + 1, yb(sy) - sh + 1, 26, sh - 2, step=7, color=HATCH, lw=0.55)
    hatch(c, ix + iw - 27, yb(sy) - sh + 1, 26, sh - 2, step=7, color=HATCH, lw=0.55)
    # макет — сетка этикеток
    gx = ix + 34
    gw = iw - 68
    for r in range(2):
        for k in range(7):
            ui_label_cell(c, gx + k * (gw / 7) + 2, sy + 8 + r * 22, gw / 7 - 5, 17,
                          mode="master" if (r == 0 and k == 3) else "copy")
    # подписи размеров
    c.setFillColor(GREY)
    c.setFont(F, 7)
    c.drawCentredString(ix + 14, yb(sy) - sh - 10, "поле 5")
    c.drawCentredString(ix + iw - 14, yb(sy) - sh - 10, "поле 5")
    c.drawCentredString(ix + iw / 2, yb(sy) - sh - 10, "макет 465 мм → ширина 475 мм")
    # поля формы
    fy = sy + sh + 24
    fw = 118
    ui_field(c, ix, fy, fw, "Поле слева, мм", "5")
    ui_field(c, ix + fw + 12, fy, fw, "Поле справа, мм", "5")
    ui_field(c, ix + 2 * (fw + 12), fy, fw, "Сдвиг макета, мм", "0")
    c.setFillColor(CYAN)
    c.setFont(FB, 8)
    c.drawString(ix + 3 * (fw + 12) + 4, yb(fy + 9), "Рекомендуемая ширина:")
    c.setFillColor(INK)
    c.setFont(FK, 13)
    c.drawString(ix + 3 * (fw + 12) + 4, yb(fy + 28), "475 мм")
    ui_btn(c, ix + iw - 142, fy + 6, "Применить к раскрою (полотно)", primary=True,
           h=15, size=7.5, w=142)
    ui_badge(c, ix + 40, sy + sh + 6, 1)
    ui_badge(c, ix + 58, fy + 7, 2)
    ui_badge(c, ix + 3 * (fw + 12) + 90, fy + 20, 3)
    ui_badge(c, ix + iw - 150, fy + 14, 4)
    top = top + h + 6
    top = fig_cap(c, top, "Схема блока: полотно с полями и макетом (1), поля ввода (2), "
                          "рекомендация (3) и кнопка применения (4).")
    steps = [
        ("Задайте поля слева и справа",
         "По умолчанию 5 мм — минимальный запас под зажим и подачу. Поля входят в "
         "рекомендуемую ширину полотна."),
        ("При необходимости сдвиньте макет",
         "«Сдвиг макета»: плюс — вправо, минус — влево относительно оси симметрии "
         "материала. Нужно, чтобы компенсировать перекос тиража."),
        ("Проверьте рекомендуемую ширину",
         "Строка пересчитывается автоматически: ширина макета + оба поля. Именно её "
         "целесообразно заложить в закупку полотна."),
        ("Нажмите «Применить к раскрою (полотно)»",
         "Значение подставится в поле «Полотно, мм» в разделе «Раскрой», и расчёт "
         "пересчитается под реальную ширину рулона."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "tip",
               "Сначала распознавайте массив (операция 4), затем возвращайтесь сюда: "
               "блок ширины материала появляется только после успешного распознавания.")


def page_op6_layout(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 06 · РАСКРОЙ",
        "Параметры раскроя и расчёт",
        "Раздел «Раскрой» считает расход полотна: раскладку рядов и колонок, "
        "число оборотов цилиндра, длину тиража и процент отходов. Любое изменение "
        "поля запускает пересчёт автоматически — либо нажмите «Рассчитать».")
    h = 240
    y = fig_frame(c, top, h, "РАЗДЕЛ «РАСКРОЙ»")
    ix, iw = ML + 14, CW - 28
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(ix, yb(y + 6), "Параметры раскроя")
    # сетка полей 4×3
    fields = [
        ("Этикетка W, мм", "50"), ("Этикетка H, мм", "30"),
        ("Зазор X, мм", "3"), ("Зазор Y, мм", "3"),
        ("Зубья Z", "96"), ("Шаг CP, мм", "3,175"),
        ("Цилиндр, мм", "300"), ("Полотно, мм", "300"),
        ("Подрез, мм", "0,48"), ("Мин. зазор, мм", "3"),
        ("Кол-во N", "5000"), ("Длина L, мм", "10000"),
    ]
    fw, fh = 108, 30
    for i, (lab, val) in enumerate(fields):
        col, row = i % 4, i // 4
        ui_field(c, ix + col * (fw + 8), y + 22 + row * fh, fw, lab, val)
    # режим + кнопка
    my = y + 22 + 3 * fh + 6
    c.setFillColor(GREY)
    c.setFont(FB, 8)
    c.drawString(ix, yb(my + 10), "Режим расчёта:")
    ui_chip(c, ix + 78, my + 1, "по количеству", active=True, h=15, size=7.5)
    ui_chip(c, ix + 78 + 84, my + 1, "по длине", active=False, h=15, size=7.5)
    ui_btn(c, ix + iw - 86, my + 1.5, "Рассчитать", primary=True, h=15, size=8, w=86)
    # результаты
    ry = my + 30
    results = [
        ("Раскладка", "5 × 9"), ("За оборот", "45"), ("Оборотов", "112"),
        ("Этикеток N", "5040"), ("Длина, м", "34,1"), ("Отходы, %", "26,18"),
        ("На этикетку, м²", "2032"), ("Ширина полотна", "300"),
        ("Раппорт, мм", "304,8"),
    ]
    cw_ = (iw - 8 * 6) / 9
    for i, (lab, val) in enumerate(results):
        x = ix + i * (cw_ + 6)
        c.setFillColor(white)
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.7)
        c.roundRect(x, yb(ry) - 44, cw_, 44, 4, stroke=1, fill=1)
        c.setFillColor(GREY)
        c.setFont(F, 6.5)
        lab_lines = wrap(lab, F, 6.5, cw_ - 8)
        for j, ln in enumerate(lab_lines):
            c.drawCentredString(x + cw_ / 2, yb(ry) - 12 - j * 8, ln)
        c.setFillColor(INK if lab not in ("Отходы, %",) else CYAN)
        c.setFont(FK, 11.5)
        c.drawCentredString(x + cw_ / 2, yb(ry) - 34, val)
    # итоговая плашка
    py = ry + 54
    c.setFillColor(TIP_BG)
    c.setStrokeColor(TIP_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(py) - 30, iw, 30, 5, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, 9)
    c.drawString(ix + 12, yb(py) - 19,
                 "Эталон: при заказе 5000 шт выдано 5040 (загрузка 9×5), отходы 26,18 %")
    ui_badge(c, ix + 62, y + 84, 1)
    ui_badge(c, ix + 66, my + 9, 2)
    ui_badge(c, ix + iw - 96, my + 9, 3)
    ui_badge(c, ix + iw - 20, ry + 50, 4)
    top = top + h + 6
    top = fig_cap(c, top, "Схема раздела: форма параметров (1), режим тиража (2), "
                          "кнопка расчёта (3) и карточки результата (4).")
    steps = [
        ("Заполните размеры этикетки и зазоры",
         "W и H — размер в створе; зазоры X/Y — просвет между этикетками. "
         "Если массив распознан, W/H уже подставлены автоматически."),
        ("Задайте параметры цилиндра и полотна",
         "Зубья Z × шаг CP = раппорт (96 × 3,175 = 304,8 мм). Полотно — ширина "
         "рулона; число колонок ограничено min(цилиндр, полотно)."),
        ("Выберите режим тиража",
         "«По количеству» — задаёте число этикеток N; «по длине» — длину полотна L. "
         "Переключатель меняет, какое поле является исходным."),
        ("Нажмите «Рассчитать» и прочитайте карточки",
         "Раскладка, обороты, длина, отходы и расход на этикетку. Ошибка расчёта "
         "выводится строкой под формой."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW, gap=7)
    top += 12
    top = note(c, top, "tip",
               "Мини-справка по формулам — на странице 18: раппорт, шаг колонки, "
               "запас по подрезу и как связаны N, длина и отходы.")


# ==========================================================================
# Операции 7–12
# ==========================================================================
def page_op7_variants(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 07 · РАСКРОЙ",
        "Перебор вариантов раскроя",
        "Кнопка «Перебрать варианты» (Pro) перебирает комбинации раскладок, "
        "поворотов 0°/90° и заполнений, ранжирует их по отходам, длине и расходу "
        "на этикетку и предлагает выбрать лучший.")
    h = 210
    y = fig_frame(c, top, h, "ВАРИАНТЫ РАСКРОЯ")
    ix, iw = ML + 14, CW - 28
    # заголовок + кнопка
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(ix, yb(y + 6), "Варианты раскроя (12)")
    bw = sw("Перебрать варианты", FB, 8) + 16
    ui_btn(c, ix + iw - bw, y - 1, "Перебрать варианты", primary=True, h=16, size=8, w=bw)
    # таблица
    rows = [
        ("1", "5 × 9", "—", "5040", "34,1", "26,18", "2032"),
        ("2", "6 × 8", "да", "4992", "33,4", "24,05", "2015"),
        ("3", "4 × 11", "—", "4840", "35,0", "28,60", "2088"),
        ("4", "7 × 7", "да", "4998", "32,8", "22,40", "1998"),
        ("5", "5 × 10", "—", "5150", "35,2", "29,10", "2074"),
    ]
    th = ui_table(c, ix, y + 20, iw,
                  ["№", "Сетка", "Пов.", "N", "Длина, м", "Отходы, %", "На этикетку, м²"],
                  rows, col_ratios=[0.5, 1.0, 0.7, 0.9, 1.1, 1.1, 1.4],
                  row_h=15, size=8, hi_row=3)
    # панель применения
    py = y + 26 + th
    c.setFillColor(CELL_HL)
    c.setStrokeColor(CYAN)
    c.setLineWidth(0.8)
    c.roundRect(ix, yb(py) - 46, iw, 46, 5, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 8.5)
    c.drawString(ix + 12, yb(py) - 17,
                 "Выбран вариант №4: 7 × 7, N=4998, длина 32,8 м, отходы 22,40 %.")
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(ix + 12, yb(py) - 31,
                 "Он станет расчётным для ТЭО и отчётов после нажатия «Применить».")
    ui_btn(c, ix + iw - 84, py - 36, "Применить", primary=True, h=17, size=8.5, w=74)
    ui_badge(c, ix + 108, y + 7, 1)
    ui_badge(c, ix + 54, y + 60, 2)
    ui_badge(c, ix + iw - 96, py - 28, 3)
    top = top + h + 6
    top = fig_cap(c, top, "Схема: кнопка перебора (1), таблица вариантов с подсветкой "
                          "выбранной строки (2) и панель применения (3).")
    steps = [
        ("Нажмите «Перебрать варианты»",
         "Программа построит десятки раскладок — до 50 строк в таблице — и отсортирует "
         "их. Доступно в Pro: в Free появится подсказка о подписке."),
        ("Сравните строки по критериям",
         "Столбцы: сетка (ряды × колонки), поворот 0°/90°, число этикеток, длина "
         "полотна, отходы % и расход на этикетку. Подсветка — текущий выбор."),
        ("Кликните по строке-варианту",
         "Панель внизу покажет сводку выбранного: «Выбран вариант №N: …» с ключевыми "
         "цифрами расчёта."),
        ("Нажмите «Применить»",
         "Вариант становится расчётным: именно его длина и отходы уйдут в ТЭО и во "
         "все отчёты. Запись появится в журнале: «Применён вариант №N…»."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "tip",
               "Сначала сузьте диапазон параметрами (операция 6), затем перебирайте: "
               "меньше строк — быстрее выбор. Для сравнения валов используйте рейтинг "
               "Z на следующей странице.")


def page_op8_rating(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 08 · РАСКРОЙ",
        "Рейтинг по магнитным валам",
        "Раппорт = Z × CP. Если в цеху есть набор магнитных валов (Z), программа "
        "посчитает расход для каждого и покажет рейтинг — какой вал даст минимум "
        "отходов на ваш тираж.")
    h = 216
    y = fig_frame(c, top, h, "РЕЙТИНГ ВАЛОВ")
    ix, iw = ML + 14, CW - 28
    c.setFillColor(GREY)
    c.setFont(F, 8.5)
    c.drawString(ix, yb(y + 6),
                 "Раппорт = Z × CP. Расход считается для каждого вала Z из списка "
                 "и ранжируется по выбранному критерию.")
    # поле списка Z
    fy = y + 14
    ui_field(c, ix, fy, 240, "Магнитные валы, Z (через запятую)", "88, 96, 120, 176")
    bw = sw("Рассчитать рейтинг", FB, 8) + 16
    ui_btn(c, ix + 250, fy + 9, "Рассчитать рейтинг", primary=True, h=15, size=8, w=bw)
    # критерии
    cy = fy + 46
    c.setFillColor(GREY)
    c.setFont(FB, 8)
    c.drawString(ix, yb(cy + 8), "Критерий:")
    cx = ix + 58
    cx += ui_chip(c, cx, cy, "По отходам, %", active=True, h=15, size=7.5) + 6
    cx += ui_chip(c, cx, cy, "По длине, м", active=False, h=15, size=7.5) + 6
    ui_chip(c, cx, cy, "По N этикеток", active=False, h=15, size=7.5)
    # таблица рейтинга
    rows = [
        ("★ 96", "5 × 9", "5040", "34,1", "26,18", "2032"),
        ("88", "5 × 8", "4480", "30,5", "27,90", "2110"),
        ("120", "6 × 9", "5400", "36,8", "25,40", "2014"),
        ("176", "7 × 12", "8064", "54,2", "31,20", "2246"),
    ]
    th = ui_table(c, ix, cy + 24, iw,
                  ["Z", "Сетка", "N", "Длина, м", "Отходы, %", "На этикетку, м²"],
                  rows, col_ratios=[0.8, 1.0, 0.9, 1.1, 1.1, 1.4],
                  row_h=15, size=8, hi_row=0, align_center_from=1)
    # итоговая строка
    iy = cy + 30 + th
    c.setFillColor(TIP_BG)
    c.setStrokeColor(TIP_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(iy) - 34, iw, 34, 5, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 8.5)
    c.drawString(ix + 12, yb(iy) - 14,
                 "Лучший по «По отходам, %»: Z = 96, N = 5040, длина 34,1 м, отходы 26,18 %.")
    c.setFillColor(GREY)
    c.setFont(FI, 7.5)
    c.drawString(ix + 12, yb(iy) - 27,
                 "Клик по строке применяет вал Z (расчётный для ТЭО и отчётов). ★ — лучший.")
    ui_badge(c, ix + 120, fy + 16, 1)
    ui_badge(c, ix + 330, fy + 16, 2)
    ui_badge(c, ix + 140, cy + 8, 3)
    ui_badge(c, ix + iw - 30, cy + 32, 4)
    top = top + h + 6
    top = fig_cap(c, top, "Схема рейтинга: список валов (1), расчёт (2), критерий (3), "
                          "таблица с лучшим валом (4).")
    steps = [
        ("Перечислите имеющиеся валы",
         "Через запятую, по возрастанию или в любом порядке. По умолчанию — "
         "распространённый набор 88, 96, 120, 176."),
        ("Нажмите «Рассчитать рейтинг»",
         "Для каждого Z строится своя раскладка: меняются колонки, раппорт и, "
         "как следствие, отходы и длина."),
        ("Выберите критерий",
         "«По отходам, %» — минимум потерь полотна; «По длине, м» — короткое "
         "полотно; «По N этикеток» — ближе к точному тиражу без перепечатки."),
        ("Кликните строку лучшего вала",
         "Вал применяется: его Z и раскладка станут расчётными для ТЭО и отчётов; "
         "строка получит ★ и подсветку."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "tip",
               "Рейтинг удобен, когда валы уже закуплены: он честно покажет, какой из "
               "них на вашем тираже даст наименьшие отходы, ещё до согласования с цехом.")


def page_op9_teo(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 09 · ТЭО",
        "Расчёт экономико-технического обоснования",
        "ТЭО собирает себестоимость тиража из каталога затрат: сортамента "
        "(материал), машины (ставка), приладки, оснастки и наценки. На выходе — "
        "машиночасы, занято смен, ИТОГО и себестоимость 1000 шт.")
    h = 236
    y = fig_frame(c, top, h, "РАЗДЕЛ «ТЭО»")
    ix, iw = ML + 14, CW - 28
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(ix, yb(y + 6), "Каталог затрат")
    # два дропдауна
    dy = y + 14
    dw = (iw - 12) / 2
    ui_dropdown(c, ix, dy, dw, "Сортамент", "Бумага самоклеящаяся — 100 ₽/м²")
    ui_dropdown(c, ix + dw + 12, dy, dw, "Машина", "Флексо 8 красок — 5000 ₽/ч")
    # поля каталога
    fy = dy + 34
    fields = [
        ("Оснастка, ₽", "15 000"), ("Наценка, %", "20"),
        ("Приладка: материал, м", "12"), ("Смена, ч", "8"),
        ("Смен в сутки", "1"), ("Цена смены, ₽", "0"),
    ]
    fw = (iw - 5 * 8) / 6
    for i, (lab, val) in enumerate(fields):
        ui_field(c, ix + i * (fw + 8), fy, fw, lab, val)
    # кнопка
    by = fy + 42
    bw = sw("Рассчитать ТЭО", FB, 8.5) + 20
    ui_btn(c, ix + iw - bw, by - 4, "Рассчитать ТЭО", primary=True, h=17, size=8.5, w=bw)
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(ix, yb(by + 8), "Расчёт использует применённый вариант раскроя (операции 7–8).")
    # результат ТЭО
    ry = by + 26
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(ix, yb(ry + 6), "ТЭО варианта")
    ry += 16
    cells = [
        ("Маш. время, ч", "6,4"), ("С переналадкой, ч", "7,1"),
        ("Занято смен", "1"), ("Машина, ₽", "35 500"),
        ("Материал, ₽", "68 200"), ("Смена, ₽", "0"),
        ("Оснастка, ₽", "15 000"), ("Наценка, ₽", "23 740"),
    ]
    cw_ = (iw - 7 * 5) / 8
    for i, (lab, val) in enumerate(cells):
        x = ix + i * (cw_ + 5)
        c.setFillColor(white)
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.7)
        c.roundRect(x, yb(ry) - 38, cw_, 38, 4, stroke=1, fill=1)
        c.setFillColor(GREY)
        c.setFont(F, 6)
        for j, ln in enumerate(wrap(lab, F, 6, cw_ - 6)):
            c.drawCentredString(x + cw_ / 2, yb(ry) - 11 - j * 7, ln)
        c.setFillColor(INK)
        c.setFont(FB, 8.5)
        c.drawCentredString(x + cw_ / 2, yb(ry) - 30, val)
    # крупные итоги
    ky = ry + 48
    for i, (lab, val, col) in enumerate([
        ("ИТОГО, ₽", "142 440", INK),
        ("Себестоимость 1000, ₽", "28 265", CYAN),
        ("За этикетку, ₽", "0,0283", INK),
        ("Загрузка смены, %", "89", INK),
    ]):
        x = ix + i * (iw / 4)
        c.setFillColor(UI_BG)
        c.setStrokeColor(UI_LINE)
        c.setLineWidth(0.7)
        c.roundRect(x, yb(ky) - 40, iw / 4 - 8, 40, 5, stroke=1, fill=1)
        c.setFillColor(GREY)
        c.setFont(F, 7)
        c.drawString(x + 10, yb(ky) - 14, lab)
        c.setFillColor(col)
        c.setFont(FK, 14)
        c.drawString(x + 10, yb(ky) - 33, val)
    ui_badge(c, ix + 60, dy + 7, 1)
    ui_badge(c, ix + 66, fy + 7, 2)
    ui_badge(c, ix + iw - bw / 2 - 6, by + 4, 3)
    ui_badge(c, ix + iw - 24, ky + 20, 4)
    top = top + h + 6
    top = fig_cap(c, top, "Схема ТЭО: каталог затрат (1), ставки (2), расчёт (3), "
                          "итоговые карточки (4).")
    steps = [
        ("Выберите сортамент и машину",
         "Выпадающие списки берутся из каталога затрат: материал с ценой ₽/м² и "
         "машина со ставкой ₽/ч."),
        ("Задайте ставки тиража",
         "Оснастка — стоимость формы; наценка — торговый процент; приладка — метры "
         "полотна на переналадку (обычно подставляется из машины); длительность смены."),
        ("Нажмите «Рассчитать ТЭО»",
         "Появятся машиночасы, занято смен, разбивка затрат (машина, материал, "
         "оснастка, наценка) и общий ИТОГО."),
        ("Прочитайте ключевые карточки",
         "«Себестоимость 1000» — главная цифра для договора; «За этикетку» — "
         "удельная цена; «Загрузка смены» — насколько плотно занят рабочий день."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW, gap=6)
    top += 10
    top = note(c, top, "tip",
               "ТЭО считается по применённому варианту раскроя: сначала выполните "
               "операции 7–8, иначе в расчёте окажется базовая раскладка, а не лучший вариант.")


def page_op10_sensitivity(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 10 · ТЭО",
        "Чувствительность себестоимости",
        "Три ползунка позволяют мгновенно проверить: как изменится себестоимость "
        "1000 шт, если материал подорожает, вырастет ставка машины или скорость "
        "печати.")
    h = 176
    y = fig_frame(c, top, h, "БЛОК «ЧУВСТВИТЕЛЬНОСТЬ»")
    ix, iw = ML + 14, CW - 28
    sliders = [
        ("Цена материала, ₽/м²", "100", 0.16),
        ("Ставка машины, ₽/ч", "5 000", 0.23),
        ("Скорость, м/мин", "100", 0.31),
    ]
    sy = y + 8
    for lab, val, frac in sliders:
        ui_slider(c, ix, sy, iw - 150, lab, val, frac=frac)
        sy += 26
    # результат
    by = sy + 6
    bw = sw("Пересчитать", FB, 8) + 18
    ui_btn(c, ix, by, "Пересчитать", primary=True, h=17, size=8, w=bw)
    rx = ix + bw + 14
    c.setFillColor(GREY)
    c.setFont(F, 9)
    c.drawString(rx, yb(by + 12), "Себестоимость 1000 шт:")
    c.setFillColor(CYAN)
    c.setFont(FK, 17)
    c.drawString(rx + 118, yb(by + 14), "28 265 ₽")
    # шкала-подсказка
    ky = by + 30
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(ky) - 32, iw, 32, 5, stroke=1, fill=1)
    c.setFillColor(GREY)
    c.setFont(F, 8)
    c.drawString(ix + 12, yb(ky) - 13,
                 "Диапазоны: материал 20–500 ₽/м² · машина 500–20 000 ₽/ч · скорость 10–300 м/мин.")
    c.drawString(ix + 12, yb(ky) - 25,
                 "Ползунки пересчитывают итог без изменения сохранённых ставок каталога.")
    ui_badge(c, ix + 100, y + 17, 1)
    ui_badge(c, ix + bw + 4, by + 8, 2)
    ui_badge(c, rx + 170, by + 8, 3)
    top = top + h + 6
    top = fig_cap(c, top, "Схема блока чувствительности: ползунки (1), пересчёт (2), "
                          "итог (3).")
    steps = [
        ("Двигайте ползунок материала",
         "Себестоимость пересчитывается — сразу видно, как дорогой сортамент бьёт "
         "по цене тиража."),
        ("Меняйте ставку машины",
         "Проверьте сценарий «подорожало время цеха»: ставка 500–20 000 ₽/ч."),
        ("Меняйте скорость печати",
         "Скорость влияет на машиночасы: быстрее — дешевле, но выше риск перепечатки."),
        ("Нажмите «Пересчитать» и сравните",
         "Итоговая карточка «Себестоимость 1000 шт» показывает результат при "
         "текущем сочетании трёх параметров."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW, gap=8)
    top += 14
    top = note(c, top, "tip",
               "Используйте блок на переговорах: «если материал +30 %, себестоимость "
               "1000 вырастет с X до Y» — аргумент, который считается за секунды.")


def page_op11_reports(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 11 · ОТЧЁТЫ",
        "Отчёты PDF, XLSX и DXF",
        "Финальный шаг: готовые файлы для руководства (PDF), экономиста (XLSX) и "
        "производства (DXF мастера и раскроя). На вебе файлы скачивает браузер, "
        "на десктопе — сохраняются в проектную папку.")
    h = 168
    y = fig_frame(c, top, h, "РАЗДЕЛ «ОТЧЁТЫ»")
    ix, iw = ML + 14, CW - 28
    # строка назначения
    c.setFillColor(GREY)
    c.setFont(F, 8.5)
    c.drawString(ix, yb(y + 6), "Экспорт: файлы будут скачаны браузером")
    # три кнопки-карточки
    by = y + 18
    bw = (iw - 24) / 3
    reports = [
        ("PDF ТЭО", "04_ТЭО_Отчёт.pdf", "Сводка для руководства: раскладка, "
         "затраты, себестоимость.", True),
        ("XLSX", "05_Расчёт.xlsx", "Полная таблица расчёта: параметры, варианты, "
         "ТЭО — для правки в Excel.", False),
        ("DXF мастера", "02_Вылеченный_Мастер.dxf\n03_Раскрой.dxf", "Геометрия для "
         "производства: вылеченний мастер и раскрой.", False),
    ]
    for i, (btn, fname, desc, active) in enumerate(reports):
        x = ix + i * (bw + 12)
        c.setFillColor(white)
        c.setStrokeColor(CYAN if active else CARD_LINE)
        c.setLineWidth(1.1 if active else 0.7)
        c.roundRect(x, yb(by) - 112, bw, 112, 6, stroke=1, fill=1)
        c.setFillColor(CYAN)
        c.rect(x, yb(by) - 112, bw, 3, stroke=0, fill=1)
        ui_btn(c, x + 10, by + 14, btn, primary=active, h=16, size=8.5)
        c.setFillColor(INK)
        c.setFont(FB, 7.5)
        yy = by + 42
        for ln in fname.split("\n"):
            c.drawString(x + 10, yb(yy), ln)
            yy += 10
        block(c, x + 10, yy + 6, desc, F, 7.5, 10, bw - 20, GREY, max_lines=4)
    # статусная строка
    sy = by + 124
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(sy) - 26, iw, 26, 4, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(F, 8)
    c.drawString(ix + 10, yb(sy) - 16.5, "PDF сохранён: ~/Препресс-Планер/Этикетка_50x30/04_ТЭО_Отчёт.pdf")
    ui_check(c, ix + iw - 16, yb(sy - 13), r=6)
    ui_badge(c, ix + 46, by + 22, 1)
    ui_badge(c, ix + bw + 58, by + 22, 2)
    ui_badge(c, ix + 2 * (bw + 12) + 54, by + 22, 3)
    top = top + h + 6
    top = fig_cap(c, top, "Схема раздела отчётов: три формата (1–3), строка назначения "
                          "и статус выгрузки.")
    steps = [
        ("Проверьте готовность проекта",
         "PDF и XLSX формируются из применённого варианта раскроя и ТЭО; DXF мастера "
         "активен только после лечения геометрии (кнопка светлеет при готовности)."),
        ("Нажмите нужный формат",
         "Статус «Формирование PDF…» → «PDF сохранён: <путь>». В вебе — «Экспортировано: "
         "04_ТЭО_Отчёт.pdf», файл уйдёт в загрузки браузера."),
        ("Проверьте итоговые файлы",
         "04_ТЭО_Отчёт.pdf — на согласование; 05_Расчёт.xlsx — экономисту; "
         "02_Вылеченный_Мастер.dxf и 03_Раскрой.dxf — в печать."),
        ("При ошибке загляните в журнал",
         "Сообщения вида «Ошибка PDF: …», «Сервис не вернул ссылку» дублируются в "
         "журнале событий — там же детали для поддержки."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW)
    top += 14
    top = note(c, top, "warn",
               "Отчёты привязаны к применённому варианту (операция 7). Если выбрали "
               "вариант после последнего расчёта ТЭО — пересчитайте ТЭО заново, иначе "
               "PDF уйдёт с устаревшими цифрами.")


def page_op12_account(c):
    top = page_head(
        c, "ОПЕРАЦИЯ 12 · АККАУНТ",
        "Аккаунт, подписка и организация",
        "Аккаунт открывает облако (проекты с любого устройства), подписку Pro и "
        "совместную работу в организации с ролями.")
    h = 224
    y = fig_frame(c, top, h, "ВХОД И ПОДПИСКА")
    ix, iw = ML + 14, CW - 28
    # левая половина — форма входа
    half = (iw - 16) / 2
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(ix, yb(y + 6), "Аккаунт")
    fy = y + 18
    ui_field(c, ix, fy, half, "Email", "tehnik@company.ru")
    ui_field(c, ix, fy + 34, half, "Пароль", "••••••••")
    ui_btn(c, ix, fy + 74, "Войти", primary=True, h=17, size=8.5, w=half)
    c.setFillColor(CYAN)
    c.setFont(F, 7.5)
    c.drawString(ix, yb(fy + 104), "Нет аккаунта — зарегистрироваться")
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(ix, yb(fy + 116), "Забыли пароль?")
    # статус профиля
    py = fy + 134
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(py) - 44, half, 44, 5, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, 8)
    c.drawString(ix + 10, yb(py) - 15, "Статус: Pro до 12.05.2026")
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(ix + 10, yb(py) - 28, "Устройства: 1/1 · Организация и участники")
    c.drawString(ix + 10, yb(py) - 39, "Выйти")
    # правая половина — paywall
    rx = ix + half + 16
    c.setFillColor(INK)
    c.setFont(FB, 9.5)
    c.drawString(rx, yb(y + 6), "Препресс-Планер Pro")
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    for j, ln in enumerate([
        "• неограниченные проекты",
        "• shape-расход и оптимизация",
        "• ТЭО и сравнение вариантов",
        "• экспорт PDF / XLSX / DXF",
    ]):
        c.drawString(rx, yb(y + 24 + j * 11), ln)
    ty = y + 78
    c.setFillColor(CYAN)
    c.setStrokeColor(CYAN)
    c.setLineWidth(1)
    c.roundRect(rx, yb(ty) - 40, half, 40, 5, stroke=1, fill=1)
    c.setFillColor(white)
    c.setFont(FB, 9)
    c.drawString(rx + 12, yb(ty) - 16, "Месяц — 5 000 ₽")
    c.setFont(F, 7.5)
    c.drawString(rx + 12, yb(ty) - 30, "автопродление, отмена в любой момент")
    ty2 = ty + 50
    c.setFillColor(white)
    c.setStrokeColor(CYAN)
    c.setLineWidth(1.2)
    c.roundRect(rx, yb(ty2) - 46, half, 46, 5, stroke=1, fill=1)
    c.setFillColor(CYAN)
    c.setFont(FK, 13)
    c.drawString(rx + 12, yb(ty2) - 18, "Год — 50 000 ₽")
    c.setFillColor(INK)
    c.setFont(F, 7.5)
    c.drawString(rx + 12, yb(ty2) - 33, "выгоднее · 2 месяца в подарок")
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(rx, yb(ty2 + 56), "Восстановить покупки")
    # организация
    oy = ty2 + 66
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.roundRect(ix, yb(oy) - 34, iw, 34, 5, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, 8)
    c.drawString(ix + 10, yb(oy) - 14, "Организация и участники")
    c.setFillColor(GREY)
    c.setFont(F, 7.5)
    c.drawString(ix + 10, yb(oy) - 27,
                 "Роли member / viewer / admin · приглашение по email · лимит устройств 1/1")
    ui_badge(c, ix + 40, fy + 7, 1)
    ui_badge(c, ix + 40, fy + 81, 2)
    ui_badge(c, rx + half - 20, ty2 - 23, 3)
    top = top + h + 6
    top = fig_cap(c, top, "Схема: форма входа (1), кнопка «Войти» (2), тарифы Pro (3).")
    steps = [
        ("Войдите или зарегистрируйтесь",
         "Кнопка «Войти» в шапке → email и пароль (от 6 символов). Регистрация "
         "подтверждается кодом из письма; пароль сбрасывается по ссылке «Забыли пароль?»."),
        ("Оформите подписку при необходимости",
         "Чип статуса в шапке → окно Pro: «Месяц — 5 000 ₽» или «Год — 50 000 ₽». "
         "Оплата открывается в новой вкладке, Pro активируется автоматически."),
        ("Настройте организацию",
         "«Организация и участники»: добавьте коллег по email, назначьте роль "
         "(member — работа, viewer — просмотр, admin — управление)."),
        ("Следите за лимитом устройств",
         "Лимит 1/1: вход с другого устройства вытесняет текущее. Это защита "
         "аккаунта — перелогиньтесь осознанно."),
    ]
    top += 4
    top = steps_list(c, ML, top, steps, CW, gap=7)
    top += 12
    top = note(c, top, "tip",
               "В Free доступны проекты и базовый расчёт; Геометрия, ТЭО и Отчёты "
               "открываются по подписке — при попытке появляется шторка «Эта функция "
               "доступна в Pro» с кнопкой «Оформить Pro».")


# ==========================================================================
# Страница 1 — обложка (тёмная)
# ==========================================================================
def page_cover(c):
    c.setFillColor(DARK_BG)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c, dark=True)
    crosshair(c, W - 44, 44, r=6, color=CYAN_LT)

    c.setFillColor(CYAN_LT)
    c.rect(ML, yb(84), 46, 3, stroke=0, fill=1)
    c.setFont(FB, 40)
    c.setFillColor(white)
    c.drawString(ML, yb(132), "Препресс-Планер")
    c.setFont(F, 15)
    c.setFillColor(DARK_TEXT)
    c.drawString(ML, yb(160), "Руководство пользователя")

    y = block(
        c, ML, 210,
        "Подробная инструкция по работе: от импорта векторного файла до "
        "расчёта раскроя, ТЭО и готовых отчётов.",
        F, 13, 19, 430, DARK_TEXT,
    )
    block(
        c, ML, y + 16,
        "12 операций · схемы экранов · пояснения по каждому шагу",
        FB, 11.5, 16, 430, CYAN_LT,
    )

    # правая панель: step-and-repeat сетка этикеток
    px, ptop, pw, ph = 360, 320, W - ML - 360, 300
    c.setStrokeColor(DARK_LINE)
    c.setLineWidth(1)
    c.rect(px, yb(ptop) - ph, pw, ph, stroke=1, fill=0)
    ix, iy = px + 18, yb(ptop) - 18
    iw, ih = pw - 36, ph - 36
    cols, rows, cw_, gap = 4, 4, (iw - 3 * 10) / 4, 10.0
    ch = cw_ * 30 / 50
    grid_h = rows * ch + (rows - 1) * gap
    for r in range(rows):
        for k in range(cols):
            x = ix + k * (cw_ + gap)
            yy = iy - grid_h + r * (ch + gap)
            hl = (r == 1 and k == 2)
            c.setFillColor(HexColor("#14324A") if hl else DARK_BG)
            c.setStrokeColor(CYAN_LT if hl else HexColor("#3E4C66"))
            c.setLineWidth(1.3 if hl else 0.8)
            c.roundRect(x, yy, cw_, ch, 3, stroke=1, fill=1)
    waste_y = iy - grid_h - 4
    hatch(c, ix, waste_y - 24, iw, 24, step=9, color=HexColor("#2A3448"), lw=0.6)
    crosshair(c, px + pw - 16, yb(ptop) + 0 - 16, r=5, color=CYAN_LT)
    c.setFont(FI, 9)
    c.setFillColor(DARK_BODY)
    c.drawString(px, yb(ptop + ph) + 16, "Этикетка 50 × 30 мм · зазор 3 мм · Z = 96")

    # левый нижний блок — состав руководства
    items = [
        "Обзор интерфейса и навигации",
        "Операции 1–6: проект, импорт, лечение, массив, раскрой",
        "Операции 7–12: варианты, валы, ТЭО, отчёты, аккаунт",
        "Справка по формулам, частые ошибки, чек-лист",
    ]
    ly = 470
    c.setFont(FB, 8.5)
    c.setFillColor(CYAN_LT)
    track(c, ML, ly, "В ЭТОМ РУКОВОДСТВЕ", FB, 8.5, 1.6, CYAN_LT)
    ly += 16
    for it in items:
        c.setFillColor(DARK_BODY)
        c.circle(ML + 3, yb(ly + 4) + 1.5, 1.8, stroke=0, fill=1)
        c.setFillColor(DARK_TEXT)
        c.setFont(F, 10)
        c.drawString(ML + 14, yb(ly + 8), it)
        ly += 17

    track(c, ML, H - 60, "IOS · WINDOWS · MACOS · LINUX · WEB", FB, 9.5, 1.4, white)
    c.setFont(F, 8)
    c.setFillColor(DARK_BODY)
    c.drawRightString(W - ML, yb(H - 60), "prepressplan.ru")


# ==========================================================================
# Страница 16 — сквозной сценарий
# ==========================================================================
def page_pipeline(c):
    top = page_head(
        c, "СЦЕНАРИЙ",
        "Сквозной путь: файл → отчёт",
        "Семь шагов, которые проходит каждый проект. Порядок повторяет панель "
        "разделов слева — идите по ней от начала до конца.")
    steps = [
        ("Импорт", "DXF, SVG, PDF локально; AI, CDR, EPS — серверная конвертация."),
        ("Диагностика", "Разрывы, пересечения, дубликаты и «пыль» — со списком «Исправить»."),
        ("Лечение", "Морфология и топология: контур замыкается, массив пересобирается."),
        ("Массив", "Распознавание step & repeat или ручная генерация сетки."),
        ("Раскрой", "Расход по форме этикетки, перебор вариантов и рейтинг валов Z."),
        ("ТЭО", "Сортамент, машина, переналадка → себестоимость 1000 шт."),
        ("Отчёты", "PDF ТЭО, XLSX с расчётом, DXF мастера и раскроя."),
    ]
    # вертикальная лента
    n = len(steps)
    row_h = 52
    ty = top + 16
    lx = ML + 16
    c.setStrokeColor(HexColor("#C9D5E2"))
    c.setLineWidth(1.4)
    c.line(lx, yb(ty), lx, yb(ty + (n - 1) * row_h))
    for i, (name, desc) in enumerate(steps):
        yy = ty + i * row_h
        # узел
        c.setFillColor(PAPER)
        c.setStrokeColor(CYAN)
        c.setLineWidth(1.6)
        c.circle(lx, yb(yy), 13, stroke=1, fill=1)
        c.setFillColor(CYAN)
        c.setFont(FK, 10)
        num = str(i + 1)
        c.drawString(lx - sw(num, FK, 10) / 2, yb(yy) - 3.5, num)
        # карточка
        cx = lx + 30
        cwid = CW - 30 - 16
        c.setFillColor(white)
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.7)
        c.roundRect(cx, yb(yy) - 20, cwid, 40, 6, stroke=1, fill=1)
        c.setFillColor(INK)
        c.setFont(FB, 11)
        c.drawString(cx + 14, yb(yy) + 4, name)
        c.setFillColor(GREY)
        c.setFont(F, 9)
        c.drawString(cx + 14, yb(yy) - 10, desc)
        # раздел-тег справа
        tag = ["Геометрия", "Геометрия", "Геометрия", "Геометрия",
               "Раскрой", "ТЭО", "Отчёты"][i]
        c.setFillColor(UI_BG)
        c.setStrokeColor(UI_LINE)
        c.setLineWidth(0.6)
        tw = sw(tag, FB, 7.5) + 14
        c.roundRect(cx + cwid - tw - 10, yb(yy) - 7, tw, 14, 7, stroke=1, fill=1)
        c.setFillColor(GREY)
        c.setFont(FB, 7.5)
        c.drawString(cx + cwid - tw - 10 + 7, yb(yy) - 3.5, tag)
    top = ty + (n - 1) * row_h + 44
    # артефакты
    track(c, ML, top, "АРТЕФАКТЫ ПРОЕКТА", FB, 8.5, 1.6, CYAN)
    top += 12
    h = 54
    card(c, ML, top, CW, h, fill=white, stroke=CARD_LINE, r=6)
    chain = ("01_Исходник  →  02_Вылеченный_Мастер  →  03_Раскрой  →  "
             "04_ТЭО_Отчёт  →  05_Расчёт")
    c.setFont(F, 9.5)
    c.setFillColor(INK)
    c.drawString(ML + (CW - sw(chain, F, 9.5)) / 2, yb(top + 24), chain)
    block(c, ML + 16, top + 44,
          "Каждый шаг сохраняется в проект — можно вернуться на любой этап и пересчитать.",
          FI, 8.5, 11, CW - 32, GREY)


# ==========================================================================
# Страница 17 — частые ошибки
# ==========================================================================
def page_errors(c):
    top = page_head(
        c, "ДИАГНОСТИКА",
        "Частые ошибки и сообщения",
        "Сообщения, которые чаще всего встречаются при работе, и что делать в "
        "каждом случае. Все они дублируются в журнале событий.")
    rows = [
        ("Файл не найден: <путь>", "Проверьте путь или выберите файл кнопкой «Обзор…»."),
        ("Ошибка разбора файла", "Файл повреждён или в неподдерживаемом варианте "
                                 "формата — пересохраните из редактора."),
        ("Разбор дольше 90 с", "Файл слишком сложный — упростите контуры или "
                               "конвертируйте в DXF/SVG."),
        ("Сервер конвертации недоступен", "Нажмите «Запустить сервер» и проверьте "
                                          "сеть: AI/CDR/EPS требуют локальный конвертер."),
        ("Массив не найден", "Файл содержит одиночный контур — постройте сетку "
                             "вручную параметрами раскроя."),
        ("Не удалось вылечить мастер", "Сначала исправьте ошибки геометрии "
                                       "(операция 3) и повторите распознавание."),
        ("Массив не распознан — сетку не построить", "Сначала выполните «Распознать "
                                                     "массив» на вкладке «Геометрия»."),
        ("Проект «X» уже существует", "Выберите другое имя проекта."),
        ("Второй проект доступен в Pro", "Free-режим хранит один проект — оформите "
                                         "подписку для второго."),
        ("Эта функция доступна в Pro", "Геометрия, ТЭО и Отчёты открываются по "
                                       "подписке: «Оформить Pro» в шторке."),
        ("Ошибка расчёта: …", "Проверьте параметры: Z, CP, ширина полотна и зазоры "
                              "не должны давать отрицательное заполнение."),
        ("Кириллический шрифт не загружен", "Переустановите приложение: повреждён "
                                            "ресурс шрифта отчётов."),
    ]
    # таблица в два столбца
    th = 16
    x = ML
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.rect(x, yb(top) - th, CW, th, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, 8.5)
    c.drawString(x + 8, yb(top) - 11.5, "Сообщение")
    c.drawString(x + CW * 0.44 + 8, yb(top) - 11.5, "Что сделать")
    yy = top + th
    for i, (msg, fix) in enumerate(rows):
        rh = 34
        c.setFillColor(white if i % 2 == 0 else HexColor("#FBFAF7"))
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.6)
        c.rect(x, yb(yy), CW, rh, stroke=1, fill=1)
        c.setFillColor(SEV_HIGH if i in (0, 1, 5) else INK)
        c.setFont(FB, 8)
        for j, ln in enumerate(wrap(msg, FB, 8, CW * 0.44 - 16)[:2]):
            c.drawString(x + 8, yb(yy) - 12 - j * 10, ln)
        c.setFillColor(GREY)
        c.setFont(F, 8)
        for j, ln in enumerate(wrap(fix, F, 8, CW * 0.56 - 16)[:3]):
            c.drawString(x + CW * 0.44 + 8, yb(yy) - 12 - j * 10, ln)
        yy += rh
    top = yy + 14
    top = note(c, top, "tip",
               "Не нашли сообщение? Откройте журнал событий (иконка в шапке), нажмите "
               "«Копировать всё» и отправьте текст в поддержку — в записи есть время, "
               "уровень и источник (Геометрия, Раскрой, Отчёты).")


# ==========================================================================
# Страница 18 — справка: параметры и формулы
# ==========================================================================
def page_reference(c):
    top = page_head(
        c, "СПРАВКА",
        "Параметры раскроя и формулы",
        "Краткая справка к разделу «Раскрой»: что означает каждое поле и как "
        "связаны ключевые величины.")
    # таблица параметров
    rows = [
        ("Этикетка W, мм", "50", "Ширина этикетки в створе (по полотну)"),
        ("Этикетка H, мм", "30", "Высота этикетки"),
        ("Зазор X, мм", "3", "Просвет между колонками"),
        ("Зазор Y, мм", "3", "Просвет между рядами"),
        ("Зубья Z", "96", "Число зубьев магнитного вала (раппорт)"),
        ("Шаг CP, мм", "3,175", "Шаг зуба; флексо-стандарт 1/8″"),
        ("Цилиндр, мм", "300", "Рабочая ширина цилиндра печати"),
        ("Полотно, мм", "300", "Ширина рулона материала"),
        ("Подрез, мм", "0,48", "Запас на обрезку края полотна"),
        ("Мин. зазор, мм", "3", "Минимально допустимый просвет"),
        ("Кол-во N", "5000", "Тираж в штуках (режим «по количеству»)"),
        ("Длина L, мм", "10000", "Длина полотна (режим «по длине»)"),
    ]
    th = 15
    x = ML
    c.setFillColor(UI_BG)
    c.setStrokeColor(UI_LINE)
    c.setLineWidth(0.7)
    c.rect(x, yb(top) - th, CW, th, stroke=1, fill=1)
    c.setFillColor(INK)
    c.setFont(FB, 8)
    widths = [CW * 0.26, CW * 0.14, CW * 0.60]
    c.drawString(x + 6, yb(top) - 10.5, "Параметр")
    c.drawString(x + widths[0] + 6, yb(top) - 10.5, "По умолч.")
    c.drawString(x + widths[0] + widths[1] + 6, yb(top) - 10.5, "Что означает")
    yy = top + th
    for i, (p, d, desc) in enumerate(rows):
        rh = 17
        c.setFillColor(white if i % 2 == 0 else HexColor("#FBFAF7"))
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.55)
        c.rect(x, yb(yy), CW, rh, stroke=1, fill=1)
        c.setFillColor(INK)
        c.setFont(FB, 8)
        c.drawString(x + 6, yb(yy) - 11.5, p)
        c.setFillColor(CYAN)
        c.setFont(FB, 8)
        c.drawString(x + widths[0] + 6, yb(yy) - 11.5, d)
        c.setFillColor(GREY)
        c.setFont(F, 8)
        c.drawString(x + widths[0] + widths[1] + 6, yb(yy) - 11.5, desc)
        yy += rh
    top = yy + 16
    # формулы
    track(c, ML, top, "ФОРМУЛЫ", FB, 8.5, 1.6, CYAN)
    top += 12
    formulas = [
        ("Раппорт = Z × CP", "96 × 3,175 = 304,8 мм — длина повтора этикетки "
                             "вдоль полотна."),
        ("Шаг колонки = W + зазор X", "50 + 3 = 53 мм — шаг сетки по горизонтали; "
                                      "по вертикали H + зазор Y."),
        ("Число колонок ≤ min(цилиндр, полотно)", "Заполнение по ширине ограничено "
                                                  "рабочей шириной и рулоном."),
        ("Раскладка = ряды × колонки", "Этикеток за оборот = ряды × колонки; "
                                       "обороты = ceil(N ÷ за оборот)."),
        ("Отходы, % = 1 − (N × S этикетки) ÷ (L × полотно)", "Чистая доля материала "
                                                             "в полотне; показатель «на этикетку» включает зазоры и отходы."),
        ("Себестоимость 1000 = ИТОГО ÷ N × 1000", "Ключевая цифра ТЭО для "
                                                   "сравнения вариантов и переговоров."),
    ]
    for i, (f, desc) in enumerate(formulas):
        col, row = i % 2, i // 2
        fw = (CW - 14) / 2
        fx = ML + col * (fw + 14)
        fy = top + row * 56
        c.setFillColor(white)
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.7)
        c.roundRect(fx, yb(fy) - 48, fw, 48, 6, stroke=1, fill=1)
        c.setFillColor(CYAN)
        c.rect(fx, yb(fy) - 48, 3, 48, stroke=0, fill=1)
        c.setFillColor(INK)
        c.setFont(FB, 9)
        c.drawString(fx + 12, yb(fy) - 15, f)
        block(c, fx + 12, fy + 24, desc, F, 8, 10.5, fw - 24, GREY, max_lines=3)


# ==========================================================================
# Страница 19 — журнал и советы
# ==========================================================================
def page_journal(c):
    top = page_head(
        c, "ОТЛАДКА",
        "Журнал событий и рабочие советы",
        "Журнал — лента всех действий программы: импорт, лечение, расчёт, отчёты "
        "и ошибки. Его удобно копировать при обращении в поддержку.")
    h = 148
    y = fig_frame(c, top, h, "ОКНО «ЖУРНАЛ СОБЫТИЙ»")
    ix, iw = ML + 14, CW - 28
    # кнопки окна
    ui_btn(c, ix, y + 2, "Копировать всё (24)", h=15, size=7.5)
    ui_btn(c, ix + 110, y + 2, "Очистить", h=15, size=7.5)
    ui_btn(c, ix + 170, y + 2, "Закрыть", h=15, size=7.5)
    # лента записей
    ly = y + 28
    entries = [
        ("09:41:02", "[info]", "[App]", "Препресс-Планер запущен.", GREY),
        ("09:41:15", "[info]", "[Геометрия]", "Загружено контуров: 128; ошибок: 3.", GREY),
        ("09:41:31", "[warn]", "[Геометрика]", "Применение исправления: разрыв 0,18 мм.", SEV_MID),
        ("09:41:44", "[info]", "[Геометрия]", "Массив: 5×9 (45 копий), этикетка 50×30 мм.", GREY),
        ("09:42:03", "[info]", "[Раскрой]", "Применён вариант №4: 7×7, отходы 22,40 %.", CYAN),
        ("09:42:19", "[error]", "[Отчёты]", "Ошибка PDF: нет доступа к папке.", SEV_HIGH),
    ]
    for t, lvl, src, msg, col in entries:
        c.setFillColor(HexColor("#FAFAF7"))
        c.setStrokeColor(CARD_LINE)
        c.setLineWidth(0.55)
        c.roundRect(ix, yb(ly) - 15, iw, 15, 3, stroke=1, fill=1)
        c.setFillColor(GREY)
        c.setFont("Courier", 7)
        c.drawString(ix + 6, yb(ly) - 10.5, t)
        c.setFillColor(col)
        c.setFont("Courier-Bold", 7)
        c.drawString(ix + 52, yb(ly) - 10.5, lvl)
        c.setFillColor(GREY)
        c.setFont("Courier", 7)
        c.drawString(ix + 96, yb(ly) - 10.5, src)
        c.setFillColor(INK)
        c.setFont(F, 7.5)
        c.drawString(ix + 160, yb(ly) - 10.5, msg)
        ly += 17
    ui_badge(c, ix + 62, y + 9, 1)
    ui_badge(c, ix + iw - 22, ly - 26, 2)
    top = top + h + 6
    top = fig_cap(c, top, "Схема журнала: кнопки действий (1) и записи с уровнем, "
                          "источником и сообщением (2).")
    # советы
    track(c, ML, top + 6, "РАБОЧИЕ СОВЕТЫ", FB, 8.5, 1.6, CYAN)
    top += 18
    tips = [
        ("Зум и панорама", "Колесо мыши — зум (×1,15 за шаг), перетаскивание — панорама. "
                           "При первом открытии холст сам вписывает файл в экран."),
        ("Подсказки полей", "Наведите курсор на подпись параметра — всплывает формула "
                            "или стандарт (например, CP = 1/8″ = 3,175 мм)."),
        ("Порядок работы", "Импорт → исправление ошибок → распознавание массива → "
                           "ширина материала → раскрой → ТЭО → отчёты."),
        ("Автосохранение", "Проект сохраняется при каждом изменении — не бойтесь "
                           "закрыть программу: данные не потеряются."),
        ("Быстрый возврат", "Имя проекта в шапке напоминает, над каким тиражем вы "
                            "работаете; переключение — вкладкой «Проекты»."),
        ("Копирование ошибок", "В журнале «Копировать всё» переносит записи в буфер — "
                               "удобно вставлять в письмо поддержке."),
    ]
    top = steps_list(c, ML, top, tips, CW, gap=7, lead_size=9.5, body_size=9, leading=12)


# ==========================================================================
# Страница 20 — чек-лист (тёмная)
# ==========================================================================
def page_checklist(c):
    c.setFillColor(DARK_BG)
    c.rect(0, 0, W, H, stroke=0, fill=1)
    crop_marks(c, dark=True)
    track(c, ML, 44, "БЫСТРЫЙ СТАРТ", FB, 8.5, 1.6, CYAN_LT)
    c.setFont(FB, 26)
    c.setFillColor(white)
    c.drawString(ML, yb(88), "Чек-лист первого тиража")
    block(c, ML, 114,
          "Восемь пунктов от файла заказчика до готового PDF. Отмечайте по мере работы.",
          F, 11.5, 16, 500, DARK_TEXT)
    items = [
        ("Создать проект", "Вкладка «Проекты» → имя → «Создать»."),
        ("Импортировать файл", "«Обзор…» → «Импорт»; для AI/CDR/EPS запустить сервер."),
        ("Исправить ошибки", "Список «Ошибки технологичности» → «Исправить» по каждой строке."),
        ("Распознать массив", "Кнопка «Распознать массив» → проверить итог 5×9 и шаг."),
        ("Задать ширину материала", "Поля слева/справа → «Применить к раскрою (полотно)»."),
        ("Рассчитать раскрой", "Параметры → «Рассчитать» → оценить отходы и длину."),
        ("Выбрать вариант и ТЭО", "«Перебрать варианты» → «Применить» → «Рассчитать ТЭО»."),
        ("Выгрузить отчёты", "PDF ТЭО, XLSX и DXF мастера — отправить по назначению."),
    ]
    y = 168
    for i, (name, desc) in enumerate(items):
        col, row = i % 2, i // 2
        fw = (CW - 16) / 2
        fx = ML + col * (fw + 16)
        fy = y + row * 84
        c.setFillColor(DARK_CARD)
        c.setStrokeColor(DARK_LINE)
        c.setLineWidth(0.8)
        c.roundRect(fx, yb(fy) - 68, fw, 68, 6, stroke=1, fill=1)
        # чекбокс
        c.setStrokeColor(CYAN_LT)
        c.setLineWidth(1.3)
        c.roundRect(fx + 14, yb(fy) - 34, 15, 15, 3, stroke=1, fill=0)
        # галочка
        c.setStrokeColor(CYAN_LT)
        c.setLineWidth(1.5)
        p = c.beginPath()
        p.moveTo(fx + 17.5, yb(fy) - 26)
        p.lineTo(fx + 21, yb(fy) - 30)
        p.lineTo(fx + 26.5, yb(fy) - 22)
        c.drawPath(p, stroke=1, fill=0)
        c.setFillColor(white)
        c.setFont(FB, 11)
        c.drawString(fx + 40, yb(fy) - 24, f"{i+1}. {name}")
        block(c, fx + 40, fy + 34, desc, F, 8.5, 11.5, fw - 56, DARK_TEXT, max_lines=3)
    # подвал
    fy = y + 4 * 84 + 8
    c.setStrokeColor(DARK_LINE)
    c.setLineWidth(0.75)
    c.line(ML, yb(fy), W - ML, yb(fy))
    c.setFont(FB, 15)
    c.setFillColor(white)
    c.drawString(ML, yb(fy + 30), "Препресс-Планер")
    c.setFont(F, 9.5)
    c.setFillColor(DARK_BODY)
    c.drawString(ML, yb(fy + 48),
                 "Вопросы и поддержка: prepressplan.ru · юридические документы: prepressplan.ru/legal")
    track(c, ML, fy + 74, "IOS · WINDOWS · MACOS · LINUX · WEB", FB, 9, 1.4, DARK_TEXT)
    crosshair(c, W - ML - 12, yb(fy + 40), r=10, color=CYAN_LT)
    page_chrome(c, 20, dark=True)


# ==========================================================================
def main():
    register_fonts()
    out = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "Препресс-Планер_руководство.pdf")
    c = canvas.Canvas(out, pagesize=(W, H))
    c.setTitle("Препресс-Планер — руководство пользователя")
    c.setAuthor("Препресс-Планер")
    c.setSubject("Инструкция по операциям: импорт, лечение, раскрой, ТЭО, отчёты")
    pages = [
        page_cover, page_toc, page_overview,
        page_op1_projects, page_op2_import, page_op3_diagnose, page_op4_array,
        page_op5_width, page_op6_layout, page_op7_variants, page_op8_rating,
        page_op9_teo, page_op10_sensitivity, page_op11_reports, page_op12_account,
        page_pipeline, page_errors, page_reference, page_journal, page_checklist,
    ]
    for i, fn in enumerate(pages, 1):
        page_head.num = i
        fn(c)
        c.showPage()
    c.save()
    print(out)


if __name__ == "__main__":
    main()



