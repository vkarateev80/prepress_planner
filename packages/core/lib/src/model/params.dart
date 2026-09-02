/// Параметры раскроя (эталонные дефолты из cam_material/config.py).
class LayoutParams {
  double labelW;
  double labelH;
  double gapX;
  double gapY;
  int zTeeth;
  double cp;
  double rapportManual; // > 0 → ручной раппорт вместо Z·CP
  double cylWidth;
  double webWidth;
  double undercut;
  double minGap;
  String mode; // 'count' | 'length'
  int count;
  double length;

  LayoutParams({
    this.labelW = 50.0,
    this.labelH = 30.0,
    this.gapX = 3.0,
    this.gapY = 3.0,
    this.zTeeth = 96,
    this.cp = 3.175,
    this.rapportManual = 0.0,
    this.cylWidth = 300.0,
    this.webWidth = 300.0,
    this.undercut = 0.48,
    this.minGap = 3.0,
    this.mode = 'count',
    this.count = 5000,
    this.length = 10000.0,
  });

  LayoutParams copyWith({
    double? labelW,
    double? labelH,
    double? gapX,
    double? gapY,
    int? zTeeth,
    double? cp,
    double? rapportManual,
    double? cylWidth,
    double? webWidth,
    double? undercut,
    double? minGap,
    String? mode,
    int? count,
    double? length,
  }) =>
      LayoutParams(
        labelW: labelW ?? this.labelW,
        labelH: labelH ?? this.labelH,
        gapX: gapX ?? this.gapX,
        gapY: gapY ?? this.gapY,
        zTeeth: zTeeth ?? this.zTeeth,
        cp: cp ?? this.cp,
        rapportManual: rapportManual ?? this.rapportManual,
        cylWidth: cylWidth ?? this.cylWidth,
        webWidth: webWidth ?? this.webWidth,
        undercut: undercut ?? this.undercut,
        minGap: minGap ?? this.minGap,
        mode: mode ?? this.mode,
        count: count ?? this.count,
        length: length ?? this.length,
      );
}

/// Параметры анализа технологичности.
class ManufacturingParams {
  double tolerance; // допуск замыкания контуров, мм (2.0)
  double minLoopArea; // мин. площадь «пыли», мм² (1.0)
  double minRadius; // мин. радиус внутренних углов, мм (0.2)
  double minGap; // мин. зазор между контурами, мм (0.5)

  ManufacturingParams({
    this.tolerance = 2.0,
    this.minLoopArea = 1.0,
    this.minRadius = 0.2,
    this.minGap = 0.5,
  });
}
