# Агент 06 — Технологичность: проверки, вердикт, авто-исправления (packages/core/lib/src/manufacturability/)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — актуально. Контракт соответствует коду (`packages/core/lib/src/manufacturability/`); проверки пересечений/дубликатов на больших файлах ускорены bbox-сетками (`2f1513c`) с тем же результатом — дельт по теме нет.

## Роль
Порт анализа технологичности из `cam_material/src/manufacturability/` в Dart. Потребляет аг.01 (geom), аг.03 (healer), модель Issue (аг.00).

## Источники (читать)
- `cam_material/src/manufacturability/geometry_checks.py` (проверки)
- `cam_material/src/manufacturability/analyzer.py` (сборка отчёта, вердикт, авто-исправления)
- `cam_material/tests/test_manufacturability.py` (эталон)

## Создаваемые файлы
```
packages/core/lib/src/manufacturability/geometry_checks.dart
packages/core/lib/src/manufacturability/analyzer.dart
packages/core/test/manufacturability_test.dart
```

## Интерфейс (ТОЧНО)

```dart
class AnalysisReport {
  final List<Issue> issues;
  final String verdict;          // «Технологично» | «Внимание (N предупреждений)» | «Требует исправлений (N критич.)»
  final Map<String, int> counts; // error/warning/suggestion
  final bool ok;
}

AnalysisReport analyzeManufacturability(List<CamPath> paths, ManufacturingParams p);
List<CamPath> healGeometry(List<CamPath> paths, ManufacturingParams p);   // healer + topology
List<CamPath> removeDustPaths(List<CamPath> paths, double minLoopArea);
List<CamPath> applyIssueFix(List<CamPath> paths, Issue issue, ManufacturingParams p);
```

## Проверки (порт 1:1 из geometry_checks.py — severity ТОЧНО как в Python)
| kind | что ищет | severity (Python) | fixable |
|---|---|---|---|
| `open` | незамкнутые контуры | **error** | да (лечение) |
| `intersection` | самопересечение контура ИЛИ пересечение двух контуров (длина пересечения ≤ 0.01) | **warning** | да (лечение) |
| `duplicate` | наложенные сегменты (длина пересечения > 0.01 мм), внутри контура или между контурами | **warning** | да (лечение) |
| `dust` | замкнутый контур площадью < minLoopArea или линия короче | warning | да (удаление) |
| `sharp_corner` | разворот лезвия > 90° (turn_deg); r_max = min(длин сторон)·tan(wedge/2) < minRadius → error, иначе suggestion | error/suggestion | нет |
| `small_gap` | расстояние между контурами 0 < d < minGap (лимит пар 300) | warning | нет |

Порядок сборки, тексты сообщений («Пыль/мусор: контур №N…», «Разомкнутый контур №N…» и т.д.) и точки-маркеры — как в python (русские; см. geometry_checks.py). Формулы sharp_corner: `turn_deg = |π − theta|·180/π`, где theta — внутренний угол из dot/cross с учётом выпуклости (is_convex = cross>0 == area>0); `wedge = min(theta, 2π−theta)`; `r_max = min(l_in,l_out)·tan(wedge/2)`.

## Авто-исправления (порт analyzer.py)
- `applyIssueFix`: dust → removeDustPaths; open/intersection/duplicate → healGeometry; иначе вернуть paths без изменений.
- `healGeometry`: MorphologicalHealer(tolerance, minLoopArea) → TopologicalOptimizer(0.001).
- Повторный `analyzeManufacturability` после фикса должен уменьшать счётчики.

## Тесты (порт + фикстуры)
1. `fixtures/petlya_open_artifacts.dxf`: analyze → есть `open` (error) и, вероятно, `dust`; ok=false; вердикт «Требует исправлений».
2. `applyIssueFix` для open → повторный analyze: open больше нет (или стало меньше).
3. `healGeometry` на petlya_open_artifacts: все контуры замкнуты (кроме HEALED_TAIL).
4. `fixtures/quadroring.dxf` (чистый массив): нет error (возможны warning'и) — сверять с test_manufacturability.py.
5. Пыль: маленький квадрат 0.3×0.3 при minLoopArea=1.0 → kind=dust, fixable.
6. Острый угол: L-образный контур с углом 45° и minRadius=0.2: если вписывается скругление → suggestion, иначе error (порт логики из geometry_checks.py — сверить точное условие с python).
7. Не падает на пустом/вырожденном входе.

## Критерии приёмки
1. Все тесты зелёные. 2. Только stdlib. 3. Сигнатуры точные (UI аг.09 вызывает эти функции).
