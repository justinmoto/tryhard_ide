import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:tryhard_ide/services/chat_history_store.dart';
import 'package:tryhard_ide/services/ollama_service.dart';
import 'package:tryhard_ide/services/repo_index.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// Embeds by counting a few vocabulary words, so similar texts point the same way.
class _FakeOllama extends OllamaService {
  _FakeOllama({this.fail = false});

  final bool fail;
  int embedCalls = 0;
  static const _vocab = ['login', 'password', 'cart', 'checkout', 'theme', 'color'];

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    if (fail) throw Exception('Embedding model "nomic-embed-text" not found.');
    embedCalls += texts.length;
    return [
      for (final t in texts)
        [for (final w in _vocab) t.toLowerCase().split(w).length - 1 + 0.01],
    ];
  }
}

void main() {
  late Directory tmp;
  late Directory repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rag_test');
    repo = await Directory(p.join(tmp.path, 'repo')).create();
    PathProviderPlatform.instance =
        _FakePathProvider(p.join(tmp.path, 'support'));
    await Directory(p.join(repo.path, 'lib')).create();
    await Directory(p.join(repo.path, 'node_modules')).create();
    await File(p.join(repo.path, 'lib', 'auth.dart')).writeAsString([
      for (var i = 1; i <= 60; i++)
        i == 45 ? 'bool checkPassword(String password) => login(password);' : '// line $i',
    ].join('\n'));
    await File(p.join(repo.path, 'lib', 'cart.dart')).writeAsString(
      'class Cart {\n  void checkout() {}\n}\n',
    );
    await File(p.join(repo.path, 'node_modules', 'junk.js')).writeAsString('login');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('indexes, retrieves with line ranges, and skips vendored dirs', () async {
    final index = RepoIndex(_FakeOllama());
    await index.open(repo.path);
    await index.build();

    expect(index.fileCount, 2);
    expect(index.containsPath('node_modules/junk.js'), isFalse);
    expect(index.hasVectors, isTrue);

    final hits = await index.search('where is the password login check?');
    expect(hits, isNotEmpty);
    final top = hits.first.chunk;
    expect(top.path, 'lib/auth.dart');
    expect(top.startLine <= 45 && top.endLine >= 45, isTrue);
  });

  test('falls back to keyword search when embeddings are unavailable', () async {
    final index = RepoIndex(_FakeOllama(fail: true));
    await index.open(repo.path);
    await index.build();

    expect(index.hasVectors, isFalse);
    expect(index.embedError, contains('not found'));
    final hits = await index.search('checkout');
    expect(hits.first.chunk.path, 'lib/cart.dart');
  });

  test('persists the index and only re-embeds changed files', () async {
    final ollama = _FakeOllama();
    final first = RepoIndex(ollama);
    await first.open(repo.path);
    await first.build();
    final initialCalls = ollama.embedCalls;
    expect(initialCalls, greaterThan(0));

    final reloaded = RepoIndex(ollama);
    await reloaded.open(repo.path);
    expect(reloaded.chunkCount, first.chunkCount);
    expect(reloaded.hasVectors, isTrue);

    await reloaded.build();
    expect(ollama.embedCalls, initialCalls, reason: 'nothing changed');

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(p.join(repo.path, 'lib', 'cart.dart'))
        .writeAsString('class Cart {\n  void checkout() {}\n  void clear() {}\n}\n');
    await reloaded.build();
    expect(ollama.embedCalls, initialCalls + 1, reason: 'one changed chunk');
  });

  test('parses citations that point at indexed files', () async {
    final index = RepoIndex(_FakeOllama());
    await index.open(repo.path);
    await index.build();

    final refs = index.parseCitations(
      'See lib/auth.dart:45 and cart.dart:1-3, not lib/missing.dart:9.',
    );
    expect(refs.map((r) => r.label), ['lib/auth.dart:45', 'lib/cart.dart:1-3']);
  });

  test('chat history round-trips per workspace', () async {
    final session = ChatSession.empty()
      ..title = 'Where is login?'
      ..messages.addAll([
        const StoredChatMessage(role: 'user', content: 'Where is login?'),
        const StoredChatMessage(
          role: 'assistant',
          content: 'In lib/auth.dart:45',
          citations: [CitationRef(path: 'lib/auth.dart', startLine: 45)],
        ),
      ]);
    await ChatHistoryStore.save(repo.path, [session]);

    final loaded = await ChatHistoryStore.load(repo.path);
    expect(loaded.single.title, 'Where is login?');
    expect(loaded.single.messages.last.citations.single.label, 'lib/auth.dart:45');
    expect(await ChatHistoryStore.load(tmp.path), isEmpty);
  });
}
