# -*- coding: utf-8 -*-
"""Генератор золотого корпуса геометрии: Shapely -> JSON.

Запуск (из корня репозитория):
  cam_pipeline\venv\Scripts\python.exe packages/core/tool/gen_golden.py
Пишет: packages/core/test/golden/geom_golden.json
"""
import json
import os

from shapely.geometry import Point, Polygon, box
from shapely.ops import unary_union

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def meta(geom):
    if geom.is_empty:
        return None
    b = geom.bounds
    if geom.geom_type == "Polygon":
        rings = 1 + len(geom.interiors)
        return {"area": geom.area, "minx": b[0], "miny": b[1],
                "maxx": b[2], "maxy": b[3], "rings": rings}
    if geom.geom_type == "MultiPolygon":
        rings = 0
        area = 0.0
        for g in geom.geoms:
            area += g.area
            rings += 1 + len(g.interiors)
        return {"area": area, "minx": b[0], "miny": b[1],
                "maxx": b[2], "maxy": b[3], "rings": rings}
    return None


def main():
    out = {}
    r1, r2 = box(0, 0, 10, 10), box(5, 0, 15, 10)
    out["union_rects"] = meta(unary_union([r1, r2]))
    sq = box(0, 0, 10, 10)
    out["buffer_sq_p1"] = meta(sq.buffer(1.0))          # round join (default)
    out["buffer_sq_m1"] = meta(sq.buffer(-1.0))
    outer = Polygon([(0, 0), (20, 0), (20, 20), (0, 20)])
    hole = Polygon([(7, 7), (13, 7), (13, 13), (7, 13)])
    donut = outer.difference(hole)
    out["donut"] = meta(donut)
    out["donut_buf_p05"] = meta(donut.buffer(0.5))
    out["donut_buf_m05"] = meta(donut.buffer(-0.5))
    out["union_disjoint"] = meta(unary_union([box(0, 0, 5, 5), box(10, 10, 15, 15)]))
    # Круг как «этикетка» (проверка аппроксимации дуг) и круг с отверстием.
    circ = Point(0, 0).buffer(10.0, quad_segs=48)
    out["circle"] = meta(circ)
    out["circle_buf_p1"] = meta(circ.buffer(1.0))
    donut_c = circ.difference(Point(0, 0).buffer(4.0, quad_segs=48))
    out["circle_donut"] = meta(donut_c)
    out["circle_donut_buf_p05"] = meta(donut_c.buffer(0.5))

    # Фикстуры с замкнутыми контурами появятся на этапе парсеров (агент 02):
    # сравнения Dart↔Shapely на реальных файлах — в test/golden после готовности DxfParser.

    dest = os.path.join(ROOT, "packages", "core", "test", "golden")
    os.makedirs(dest, exist_ok=True)
    with open(os.path.join(dest, "geom_golden.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(json.dumps(out, indent=1, ensure_ascii=False))
    print("golden written")


if __name__ == "__main__":
    main()
