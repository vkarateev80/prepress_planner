# -*- coding: utf-8 -*-
"""Инспекция структуры PDF-фикстур."""
import collections
import os
import re

import fitz

for name in ["petlya.pdf", "quadroring.pdf", "petlya_open_artifacts.pdf"]:
    p = os.path.join("fixtures", name)
    data = open(p, "rb").read()
    print("==", name, "size", len(data))
    # xref-таблица или xref-поток?
    print("  has xref stream:", b"/XRef" in data[:4000])
    m = re.search(rb"startxref\s+(\d+)", data)
    print("  startxref:", m.group(1).decode() if m else None)
    doc = fitz.open(p)
    for page in doc:
        print("  page rect", page.rect)
        cont = page.get_contents()
        print("  contents refs:", cont)
        # статистика операторов в декодированном потоке страницы
        raw = b""
        for ref in cont:
            try:
                raw += doc.xref_stream(ref[0]) if isinstance(ref, tuple) else doc.xref_stream(ref)
            except Exception:
                pass
        ops = collections.Counter(re.findall(rb"(?<![A-Za-z])([a-zA-Z]{1,3})(?=\s|$)", raw))
        print("  ops:", {k.decode(): v for k, v in ops.most_common(12)})
        dr = page.get_drawings()
        print("  drawings:", len(dr), "total items:", sum(len(d["items"]) for d in dr))
        # типы XObject на странице
        res = page.get_xobjects()
        if res:
            print("  xobjects:", [(x[0], x[1], x[2]) for x in res][:6])
    doc.close()
