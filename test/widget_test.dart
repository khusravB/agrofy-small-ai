
import 'package:flutter_test/flutter_test.dart';
import 'package:agrofy_small_ai/agrofy_app.dart';

void main() {
  testWidgets('AGROFY home screen loads', (WidgetTester tester) async {
    await tester.pumpWidget(const AgrofyApp());

    expect(find.text('AGROFY'), findsOneWidget);
    expect(find.text('Добро пожаловать!'), findsOneWidget);
  });
}
