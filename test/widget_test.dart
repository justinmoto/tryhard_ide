import 'package:flutter_test/flutter_test.dart';
import 'package:tryhard_ide/main.dart';

void main() {
  testWidgets('TryHard IDE loads shell', (tester) async {
    await tester.pumpWidget(const TryHardIdeApp());
    expect(find.text('TryHard IDE'), findsOneWidget);
    expect(find.text('Local AI Chat'), findsOneWidget);
  });
}
