import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tryhard_ide/services/next_to_react.dart';
import 'package:tryhard_ide/services/ollama_service.dart';

/// Real `vite build` output (vite 5.4, ANSI colours kept) captured from a
/// migrated project, with its path replaced by {ROOT} / {ROOTW}.
List<String> fixture(String name, String root) {
  final raw = File(p.join('test', 'fixtures', 'vite', '$name.txt')).readAsStringSync();
  return const LineSplitter().convert(raw
      .replaceAll('{ROOT}', root.replaceAll(r'\', '/'))
      .replaceAll('{ROOTW}', root));
}

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tryhard_build');
    root = p.join(tmp.path, 'shop-react');
    for (final rel in ['src/app/page.tsx', 'src/components/Header.tsx']) {
      File(p.joinAll([root, ...rel.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync('export default function X() { return null; }\n');
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String rel(BuildError e) => p.relative(e.file!, from: root).replaceAll(r'\', '/');

  group('parseBuildError on real vite output', () {
    test('rollup missing export → importer', () {
      final e = NextToReactMigration.parseBuildError(fixture('missing_export', root), root)!;
      expect(rel(e), 'src/app/page.tsx');
      expect(e.message, contains('"Missing" is not exported by "src/components/Header.tsx"'));
      expect(e.message, isNot(contains('\x1B[')), reason: 'ANSI codes stripped');
      expect(e.message, isNot(contains('    at ')), reason: 'stack frames dropped');
    });

    test('unresolved import → importing file', () {
      final e = NextToReactMigration.parseBuildError(fixture('unresolved', root), root)!;
      expect(rel(e), 'src/app/page.tsx');
      expect(e.message, contains('failed to resolve import "next/image"'));
    });

    test('esbuild syntax error → broken file', () {
      final e = NextToReactMigration.parseBuildError(fixture('syntax', root), root)!;
      expect(rel(e), 'src/components/Header.tsx');
      expect(e.message, contains('Unexpected closing "head" tag'));
    });

    test('no error / file outside the project', () {
      expect(NextToReactMigration.parseBuildError(['vite v5', '✓ built in 1s'], root), isNull);
      final e = NextToReactMigration.parseBuildError(
        ['error during build:', 'file: /elsewhere/node_modules/x/index.js:1:1'],
        root,
      )!;
      expect(e.file, isNull);
    });
  });

  test('fixBuildError sends the error and related file, writes the fix', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? prompt;
    server.listen((req) async {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      prompt = ((body['messages'] as List).last as Map)['content'] as String;
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'message': {
            'role': 'assistant',
            'content': "```tsx\nimport Header from '@/components/Header';\n"
                'export default function Home() { return <Header />; }\n```',
          },
        }));
      await req.response.close();
    });

    final error = NextToReactMigration.parseBuildError(fixture('missing_export', root), root)!;
    final fixed = await NextToReactMigration(
      OllamaService(baseUrl: 'http://127.0.0.1:${server.port}'),
    ).fixBuildError(root, error);

    expect(fixed, 'src/app/page.tsx');
    expect(prompt, contains('is not exported by'));
    expect(prompt, contains('File to fix: src/app/page.tsx'));
    expect(prompt, contains('Related file (read-only): src/components/Header.tsx'));
    expect(
      File(p.join(root, 'src', 'app', 'page.tsx')).readAsStringSync(),
      contains('<Header />'),
    );
  });
}
