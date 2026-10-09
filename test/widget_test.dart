import 'package:flutter_test/flutter_test.dart';
import 'package:tryhard_ide/main.dart';

void main() {
  testWidgets('TryHard IDE loads Cursor-like shell', (tester) async {
    await tester.pumpWidget(const TryHardIdeApp());
    expect(find.text('NO FOLDER'), findsOneWidget);
    expect(find.text('New Chat'), findsOneWidget);
    expect(find.text('Agents'), findsOneWidget);
  });
}
