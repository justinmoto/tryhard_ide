import 'package:flutter_test/flutter_test.dart';
import 'package:tryhard_ide/services/edit_proposal.dart';

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

  test('parses replace fence for selection', () {
    const file = 'aaa BBB ccc';
    const reply = '```replace\nXXX\n```';
    final proposal = EditProposal.parse(
      reply,
      fileContent: file,
      selection: 'BBB',
    );
    expect(proposal, isNotNull);
    expect(proposal!.scope, EditScope.selection);
    expect(proposal.applyTo(file), 'aaa XXX ccc');
  });

  test('parses dart fence as full file replace', () {
    const file = 'void main() {}';
    const reply = '''
Here is a dashboard:

```dart
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
    expect(proposal.applyTo(file), contains('runApp'));
  });
}
