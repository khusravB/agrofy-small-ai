import '../models/crop_profile.dart';
import '../models/crop_season.dart';

/// Crop Lifecycle State Machine: какие переходы между этапами допустимы.
///
/// Этапы идут только вперёд. Вернуться назад и переписать прошлое нельзя:
/// каждый переход записывается в журнал участка отдельным событием.
class CropLifecycle {
  /// Культуры, которые убирают до цветения или у которых урожай —
  /// не плоды: для них этапы цветения и плодоношения можно пропустить.
  static const Set<String> _harvestedBeforeFruiting = {
    'alfalfa', 'onion', 'carrot', 'potato', //
    'rye', 'vetch', 'pea', 'rapeseed', 'mustard', 'phacelia',
  };

  /// Этапы, на которые можно перейти с текущего.
  static List<CropStage> allowedNext(CropStage current, {CropProfile? crop}) {
    final index = current.index;
    if (index >= CropStage.values.length - 1) {
      return const [];
    }

    final next = [CropStage.values[index + 1]];

    final canSkipFruiting = crop != null &&
        _harvestedBeforeFruiting.contains(crop.id);
    if (canSkipFruiting && current == CropStage.vegetative) {
      next.add(CropStage.harvest);
    }

    return next;
  }

  static bool canAdvance(
    CropStage from,
    CropStage to, {
    CropProfile? crop,
  }) {
    return allowedNext(from, crop: crop).contains(to);
  }

  /// Переводит цикл на следующий этап. Недопустимый переход — ошибка.
  static CropSeason advance(
    CropSeason season,
    CropStage to, {
    required DateTime at,
    CropProfile? crop,
  }) {
    if (!canAdvance(season.stage, to, crop: crop)) {
      throw StateError(
        'Переход «${season.stage.label}» → «${to.label}» недопустим',
      );
    }

    return season.copyWith(
      stage: to,
      sownAt: to == CropStage.sowing ? at : null,
      harvestedAt: to == CropStage.harvest ? at : null,
    );
  }
}
