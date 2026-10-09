import 'package:flutter_test/flutter_test.dart';
import 'package:tryhard_ide/services/edit_proposal.dart';
import 'package:tryhard_ide/services/line_diff.dart';

void main() {
  test('parses EDIT block and applies search/replace', () {
    const file = 'void main() {\n  print("hi");\n}\n';
    const reply = '''
Sure.

<<<EDIT
  print("hi");
===
  print("hello");
EDIT>>>
''';
    final proposal = EditProposal.parse(
      reply,
      fileContent: file,
      selection: '',
    );
    expect(proposal, isNotNull);
    expect(proposal!.scope, EditScope.searchReplace);
    expect(
      proposal.applyTo(file),
      'void main() {\n  print("hello");\n}\n',
    );
  });

  test('parses dart path fence as full file replace', () {
    const file = 'void main() {}';
    const reply = '''
File: lib/main.dart

```dart:lib/main.dart
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}
```
''';
    final proposal = EditProposal.parse(
      reply,
      fileContent: file,
      selection: '',
      preferFileReplace: true,
    );
    expect(proposal, isNotNull);
    expect(proposal!.scope, EditScope.file);
    expect(proposal.targetHint, 'lib/main.dart');
    expect(proposal.applyTo(file), contains('runApp'));
  });

  test('line diff marks add and remove', () {
    final lines = diffLines('a\nb\nc\n', 'a\nx\nc\n');
    expect(lines.any((l) => l.op == DiffOp.remove && l.text == 'b'), isTrue);
    expect(lines.any((l) => l.op == DiffOp.add && l.text == 'x'), isTrue);
  });
}
