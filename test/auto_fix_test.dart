import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tryhard_ide/services/auto_fix.dart';
import 'package:tryhard_ide/services/next_to_react.dart';
import 'package:tryhard_ide/services/ollama_service.dart';

/// Report = number of errors; the "model" proposes scripted versions.
Future<AutoFixOutcome<int>> run(
  List<String?> replies,
  Map<String, int> errorsFor, {
  int maxAttempts = 2,
  List<String>? disk,
}) {
  var i = 0;
  disk ??= [];
  return autoFix<int>(
    maxAttempts: maxAttempts,
    code: 'v0',
    report: errorsFor['v0']!,
    passing: (e) => e == 0,
    fixable: (e) => e > 0,
    score: (e) => -e,
    repair: (code, report) async => i < replies.length ? replies[i++] : null,
    write: (code) async => disk!.add(code),
    check: () async => errorsFor[disk!.last]!,
  );
}

void main() {
  group('autoFix', () {
    test('stops as soon as the check passes', () async {
      final disk = <String>[];
      final o = await run(['v1', 'v2', 'v3'], {'v0': 3, 'v1': 1, 'v2': 0, 'v3': 0}, disk: disk);
      expect(o.fixed, isTrue);
      expect(o.attempts, 2);
      expect(o.code, 'v2');
      expect(disk, ['v1', 'v2']);
      expect(o.note, 'Auto-fixed after 2 attempts.');
    });

    test('restores the best version when the last attempt is worse', () async {
      final disk = <String>[];
      final o = await run(['v1', 'v2'], {'v0': 3, 'v1': 1, 'v2': 5}, disk: disk);
      expect(o.fixed, isFalse);
      expect(o.restoredBest, isTrue);
      expect(o.code, 'v1');
      expect(o.report, 1);
      expect(disk, ['v1', 'v2', 'v1']);
      expect(o.note, contains('Kept the best attempt'));
    });

    test('keeps the original when every attempt is worse', () async {
      final disk = <String>[];
      final o = await run(['v1', 'v2'], {'v0': 2, 'v1': 4, 'v2': 3}, disk: disk);
      expect(o.code, 'v0');
      expect(disk.last, 'v0');
    });

    test('gives up when the model returns nothing new', () async {
      final o = await run([null], {'v0': 2});
      expect(o.attempts, 0);
      expect(o.note, 'Auto-fix: the model returned no changes.');
      final same = await run(['v0'], {'v0': 2});
      expect(same.attempts, 0);
    });

    test('does nothing when already passing', () async {
      final disk = <String>[];
      final o = await run(['v1'], {'v0': 0, 'v1': 0}, disk: disk);
      expect(o.attempts, 0);
      expect(disk, isEmpty);
    });
  });

  test('migration retries files that still import next/*', () async {
    final prompts = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      final user = ((body['messages'] as List).last as Map)['content'] as String;
      prompts.add(user);
      // First answer is still wrong; the retry is clean.
      final code = prompts.length == 1
          ? "import { useRouter } from 'next/router';\nexport default function P() { const r = useRouter(); return <p>{r.query.id}</p>; }"
          : "import { useParams } from 'react-router-dom';\nexport default function P() { const { id } = useParams(); return <p>{id}</p>; }";
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'message': {'role': 'assistant', 'content': '```jsx\n$code\n```'}}));
      await req.response.close();
    });

    final tmp = Directory.systemTemp.createTempSync('tryhard_fix');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final root = p.join(tmp.path, 'site');
    File(p.join(root, 'package.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"name":"site","dependencies":{"next":"15.0.0"}}');
    File(p.join(root, 'pages', 'post', '[id].js'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "import { useRouter } from 'next/router';\n"
        'export default function P() { const r = useRouter(); return <p>{r.query.id}</p>; }\n',
      );

    final plan = (await NextToReactMigration.plan(root))!;
    final result = await NextToReactMigration(
      OllamaService(baseUrl: 'http://127.0.0.1:${server.port}'),
    ).execute(plan, isCancelled: () => false);

    expect(prompts, hasLength(2));
    expect(prompts.last, contains('still imports next/router'));
    expect(result.leftoverNextImports, isEmpty);
    final item = plan.items.firstWhere((i) => i.rel == 'pages/post/[id].js');
    expect(item.reason, 'model (auto-fixed)');
    expect(
      File(p.join(plan.outputDir, 'pages', 'post', '[id].js')).readAsStringSync(),
      contains('useParams'),
    );

    // With auto-fix off, the leftover is reported instead.
    prompts.clear();
    final plan2 = (await NextToReactMigration.plan(root))!;
    final off = await NextToReactMigration(
      OllamaService(baseUrl: 'http://127.0.0.1:${server.port}'),
    ).execute(plan2, isCancelled: () => false, autoFixPasses: 0);
    expect(prompts, hasLength(1));
    expect(off.leftoverNextImports, ['pages/post/[id].js']);
  });
}
