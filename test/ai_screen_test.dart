import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_small_ai/screens/ai_screen.dart';
import 'package:agrofy_small_ai/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'rotation_advisor_test.dart' show sampleClimate;

void main() {
  sqfliteFfiInit();

  tearDown(() => DatabaseService.useDatabaseForTesting(null));

  Future<void> pumpAdvisor(WidgetTester tester, {bool withField = true}) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: DatabaseService.schemaVersion,
          onCreate: DatabaseService.createSchema,
          singleInstance: false,
        ),
      );
      DatabaseService.useDatabaseForTesting(db);

      if (withField) {
        final id = await DatabaseService.instance.insertField(
          const Field(
            name: 'Южное поле',
            location: 'Тест',
            area: 5,
            crop: 'Хлопок',
            latitude: 45,
            longitude: 10,
          ),
        );
        await DatabaseService.instance.saveClimate(id, sampleClimate());
      }
    });

    await tester.pumpWidget(const MaterialApp(home: AIScreen()));

    // Чтение из БД идёт в реальном времени — даём ему завершиться.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('без участков показывает подсказку', (tester) async {
    await pumpAdvisor(tester, withField: false);

    expect(find.textContaining('Добавьте участок'), findsOneWidget);
  });

  testWidgets('офлайн строит сравнение стратегий из кэша климата',
      (tester) async {
    await pumpAdvisor(tester);

    expect(find.text('Советник по севообороту'), findsOneWidget);
    expect(find.textContaining('мм/год'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('Текущий севооборот'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Текущий севооборот'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('не заменяет'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Что проверить с агрономом'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
