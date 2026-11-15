import 'package:flutter/foundation.dart';

/// Счётчик изменений данных. Экраны подписываются на него и перечитывают
/// участки, когда пользователь переключает вкладку или меняет данные.
final ValueNotifier<int> dataRevision = ValueNotifier<int>(0);

void notifyDataChanged() => dataRevision.value++;

/// Запрос на переключение нижней вкладки (индекс) из другого экрана.
final ValueNotifier<int?> requestedTab = ValueNotifier<int?>(null);
