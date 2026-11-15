/// Поправка температуры на разницу высот между полем и ячейкой NASA.
///
/// Ячейка NASA POWER около 50 км, её средняя высота в горах может
/// отличаться от высоты поля на сотни метров. Стандартный вертикальный
/// градиент — около 6,5 °C на километр.
class ElevationCorrection {
  static const double lapseRatePerM = 0.0065;

  /// Меньшие поправки не показываются как значимые.
  static const double minimumDelta = 0.3;

  final double fieldElevation;
  final double gridElevation;

  const ElevationCorrection({
    required this.fieldElevation,
    required this.gridElevation,
  });

  static ElevationCorrection? of({
    double? fieldElevation,
    double? gridElevation,
  }) {
    if (fieldElevation == null || gridElevation == null) {
      return null;
    }
    return ElevationCorrection(
      fieldElevation: fieldElevation,
      gridElevation: gridElevation,
    );
  }

  /// Поправка к температуре, °C: поле ниже ячейки — теплее.
  double get deltaT => -lapseRatePerM * (fieldElevation - gridElevation);

  bool get significant => deltaT.abs() >= minimumDelta;

  String describe() {
    final difference = (fieldElevation - gridElevation).round();
    final where = difference < 0 ? 'ниже' : 'выше';
    final sign = deltaT >= 0 ? '+' : '−';
    return 'Температура поправлена на высоту: поле ${fieldElevation.round()} м, '
        'средняя высота ячейки NASA ${gridElevation.round()} м — поле на '
        '${difference.abs()} м $where, поправка $sign'
        '${deltaT.abs().toStringAsFixed(1)} °C (градиент 6,5 °C/км).';
  }
}
