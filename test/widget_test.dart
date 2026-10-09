import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tryhard_ide/main.dart';

void main() {
  testWidgets('TryHard IDE loads shell with run controls', (tester) async {
    await tester.pumpWidget(const TryHardIdeApp());
    expect(find.text('NO FOLDER'), findsOneWidget);
    expect(find.text('AI Edits'), findsOneWidget);
    expect(find.byTooltip('Run (⌘R) — open panel & start'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsWidgets);
    expect(find.byIcon(Icons.terminal), findsWidgets);
  });
}
