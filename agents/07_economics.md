# Агент 07 — Экономика и ТЭО (packages/core/lib/src/economics/)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — актуально (дополнено после MVP).
> - Интерфейс расширен: `Machine.setupMaterialMeters` (приладка, погонные метры), `TeoInput.setupMaterialMeters`/`shiftCostPerShift` (стоимость рабочей смены), `TeoResult.shiftsUsed`/`shiftCost` — коммит `8f17b55` (см. `packages/core/lib/src/economics/machine.dart`, `teo.dart`).
> - Единицы расчёта/отчётов — м/м², приладка (материал, м), смена и её цена (см. также аг.08 и `docs/VERIFICATION.md`).

## Роль
Новый модуль: статьи затрат (сортамент, машины, рабочее время), расчёт ТЭО на вариант раскроя, сравнение вариантов, break-even, чувствительность. Потребляет аг.05 (`MaterialResult`, `Consumption`, `LabelShape`).

## Создаваемые файлы
```
packages/core/lib/src/economics/assortment.dart
packages/core/lib/src/economics/machine.dart
packages/core/lib/src/economics/teo.dart
packages/core/lib/src/economics/price_catalog.dart   // хранилище-репозиторий каталогов (JSON-сериализация)
packages/core/test/economics_test.dart
```

## Интерфейс (ТОЧНО)

```dart
class AssortmentItem {
  final String id, name;          // «Бумага самоклеящаяся 80 г/м²», «Плёнка ПЭТ 50 мкм»…
  final double pricePerM2;        // ₽/м²
  final double? minOrderM2;
}

class Machine {
  final String id, name;
  final double ratePerHour;          // ставка машино-часа, ₽/ч
  final double? speedMetersPerMin;   // рабочая скорость печати, м/мин (если задана)
  final int? labelsPerHour;          // …или этикеток/ч
  final double setupTimeHours;       // время переналадки на заказ, ч
}

class WorkTime { final double hoursPerShift; final int shiftsPerDay; }  // дефолт 8 / 1

class TeoResult {
  final String? error;
  final double runTimeHours, setupTimeHours, totalTimeHours;   // машинное время
  final double machineCost, materialCost, toolingCost, markupCost;
  final double totalCost, costPer1000, costPerLabel;
  final double labelsPerHour, labelsPerShift;
  final double shiftLoadPct;         // totalTime / (hoursPerShift·shifts)·100; >100 → warning
  final bool fitsShift;
}

class TeoInput {
  final AssortmentItem material;
  final Machine machine;
  final WorkTime workTime;
  final double toolingCost;    // ₽/заказ, 0 — нет
  final double markupPct;      // %, 0 — нет
}

TeoResult computeTeo(MaterialResult calc, Consumption cons, TeoInput input);
// runTime = calc.length (мм) / (speedMetersPerMin·1000) / 60 ч  — если speed задана,
//           иначе calc.count / labelsPerHour
// machineCost = (setup + runTime)·rate; materialCost = cons.areaM2·pricePerM2
// total = material + machine + tooling + markup·(material+machine+tooling)/100
// costPer1000 = total / calc.count·1000; shiftLoad по WorkTime

class TeoComparison {
  final List<(MaterialResult, TeoResult)> variants;  // лучший первый по costPer1000
  final int bestIndex;
  final double bestCostPer1000;
  final double baseCostPer1000;   // не-rotated базовый вариант
  final double savingsPer1000;    // base − best (₽)
  final double savingsPct;
}
TeoComparison compareTeoVariants(List<MaterialResult> variants, Consumption Function(MaterialResult) consFor, TeoInput input);
// variants — из аг.05 enumerateVariants; consFor(v) — consumption для конкретного варианта (S зависит от rotated)

double breakEvenQuantity(MaterialResult variantA, TeoResult teoA, double toolingA,
                         MaterialResult variantB, TeoResult teoB, double toolingB);
// N* = (toolingB − toolingA) / ((costPer1000A − costPer1000B)/1000); если ≤0 → 0 (всегда выгоден B)

// Чувствительность: пересчёт computeTeo при изменении pricePerM2 / webWidth / rate / speed — UI просто вызывает computeTeo повторно.
```

## JSON-сериализация каталогов
`PriceCatalog { List<AssortmentItem> assortment; List<Machine> machines; WorkTime workTime; String currency = '₽'; }`
toJson/fromJson + образцы по умолчанию (`PriceCatalog.defaults()`): 3 сортамента и 2 машины с примерными ценами (пометить в name/description, что образец).

## Тесты
1. Эталон: этикетка 50×30, сетка из аг.05 (count=5040, length=34137.6 мм, areaM2=34137.6·300/1e6=10.24128 м²). Сортамент 100 ₽/м², машина: 5000 ₽/ч, speed=100 м/мин, setup=0.5 ч, workTime 8×1.
   - runTime = calc.length (мм) / (speedMetersPerMin·1000) / 60 **часов** = 34137.6/100000/60 = 0.0056896 ч ≈ 0.0057 ч. (34.1376 м при 100 м/мин — это 0.341 минуты; ранняя версия контракта ошибочно давала 0.3414 ч, читая м/мин как м/ч.)
   - machineCost = (0.5+0.0056896)·5000 = 2528.45 ₽.
   - materialCost = 10.24128·100 = 1024.13 ₽.
   - total = 3552.58 ₽; costPer1000 = 3552.58/5040·1000 ≈ 704.88 ₽.
   - shiftLoad = 0.5056896/8·100 ≈ 6.32% → fitsShift.
2. Вариант с rotated=true (если он дешевле/дороже) — сравнение: savings ≥ 0 для лучшего; порядок сортировки по costPer1000.
3. breakEven: варианты с разной оснасткой дают корректный N*.
4. Серьёзность: скорость 0 и labelsPerHour null → error «задайте скорость печати».
5. Округления: деньги — 2 знака, время — 4, costPer1000 — 2.
