import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_storage.dart';
import 'ollama_service.dart';

/// A window of lines from one project file. Lines are 1-based, inclusive.
class CodeChunk {
  CodeChunk({
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.text,
    this.vector,
  });

  /// Project-relative path with forward slashes.
  final String path;
  final int startLine;
  final int endLine;
  final String text;

  /// L2-normalized embedding, or null when not embedded (keyword-only).
  Float32List? vector;

  String? _lower;
  String get lower => _lower ??= '${path.toLowerCase()}\n${text.toLowerCase()}';

  String get label => startLine == endLine
      ? '$path:$startLine'
      : '$path:$startLine-$endLine';
}

class RetrievedChunk {
  const RetrievedChunk(this.chunk, this.score);

  final CodeChunk chunk;
  final double score;
}

/// A `path:line` or `path:start-end` reference found in a model reply.
class CitationRef {
  const CitationRef({required this.path, required this.startLine, int? endLine})
      : endLine = endLine ?? startLine;

  final String path;
  final int startLine;
  final int endLine;

  String get label =>
      startLine == endLine ? '$path:$startLine' : '$path:$startLine-$endLine';

  Map<String, dynamic> toJson() => {'p': path, 's': startLine, 'e': endLine};

  static CitationRef fromJson(Map<String, dynamic> j) => CitationRef(
        path: j['p'] as String,
        startLine: j['s'] as int,
        endLine: j['e'] as int?,
      );
}

class _FileMeta {
  const _FileMeta(this.mtimeMs, this.size);

  final int mtimeMs;
  final int size;
}

class _StoredIndex {
  const _StoredIndex(this.embedModel, this.files, this.chunks);

  final String? embedModel;
  final Map<String, _FileMeta> files;
  final List<CodeChunk> chunks;
}

/// Local retrieval index over the open workspace.
///
/// Chunks are embedded with Ollama when the embed model is installed and
/// fall back to keyword scoring otherwise. The index is persisted per
/// workspace, and rebuilding only re-reads files whose mtime/size changed.
class RepoIndex extends ChangeNotifier {
  RepoIndex(this.ollama);

  final OllamaService ollama;

  static const _formatVersion = 1;
  static const _chunkLines = 40;
  static const _chunkStep = 30;
  static const _maxFileBytes = 256 * 1024;
  static const _maxFiles = 3000;
  static const _embedBatch = 16;

  static const _skipDirs = {
    '.git', '.dart_tool', 'build', 'node_modules', '.idea', '.vscode',
    'Pods', 'coverage', 'dist', '.next', 'ephemeral', '.gradle', 'target',
    '__pycache__', '.venv', 'venv', 'out', '.svelte-kit', '.cache',
  };
  static const _textExts = {
    '.dart', '.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx', '.py', '.json',
    '.md', '.html', '.css', '.scss', '.yaml', '.yml', '.sql', '.java', '.kt',
    '.kts', '.swift', '.go', '.rs', '.c', '.h', '.cc', '.cpp', '.hpp', '.cs',
    '.php', '.rb', '.vue', '.svelte', '.sh', '.toml', '.xml', '.gradle',
    '.txt', '.cmake',
  };
  static const _textNames = {'Dockerfile', 'Makefile', 'CMakeLists.txt'};
  static const _skipNames = {
    'pubspec.lock', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml',
    'Podfile.lock', 'Cargo.lock', 'poetry.lock',
  };

  String? _rootPath;
  Map<String, _FileMeta> _files = {};
  List<CodeChunk> _chunks = [];
  String? _embedModel;
  int _gen = 0;

  bool _busy = false;
  bool _pendingBuild = false;
  bool _pendingForce = false;
  String _status = 'Not indexed';
  int _progressDone = 0;
  int _progressTotal = 0;
  String? _embedError;

  String? get rootPath => _rootPath;
  bool get busy => _busy;
  String get status => _status;
  int get progressDone => _progressDone;
  int get progressTotal => _progressTotal;
  int get fileCount => _files.length;
  int get chunkCount => _chunks.length;
  bool get isEmpty => _chunks.isEmpty;
  String? get embedError => _embedError;
  bool get hasVectors => _chunks.any((c) => c.vector != null);

  bool containsPath(String relPath) => _files.containsKey(relPath);

  String absolutePath(String relPath) =>
      p.normalize(p.join(_rootPath!, relPath.replaceAll('/', p.separator)));

  /// Switch to [rootPath] and load its saved index (if any).
  Future<void> open(String? rootPath) async {
    if (rootPath == _rootPath) return;
    final gen = ++_gen;
    _rootPath = rootPath;
    _files = {};
    _chunks = [];
    _embedModel = null;
    _embedError = null;
    _busy = false;
    _pendingBuild = false;
    _pendingForce = false;
    _status = rootPath == null ? 'No folder open' : 'Not indexed';
    notifyListeners();
    if (rootPath == null) return;

    try {
      final file = await AppStorage.workspaceFile('rag_index', rootPath);
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final stored = await Isolate.run(() => _decode(raw));
      if (gen != _gen || stored == null) return;
      _files = stored.files;
      _chunks = stored.chunks;
      _embedModel = stored.embedModel;
      _status = _readyStatus();
      notifyListeners();
    } catch (e) {
      if (gen != _gen) return;
      _status = 'Saved index unreadable — rebuild';
      notifyListeners();
    }
  }

  /// Stop an in-progress build. Work done so far is kept.
  void cancel() {
    if (!_busy) return;
    _gen++;
    _busy = false;
    _pendingBuild = false;
    _pendingForce = false;
    _status = '${_readyStatus()} (stopped)';
    notifyListeners();
    _save();
  }

  /// Index new/changed files and drop deleted ones. [force] re-reads all.
  /// If a build is already running, queues another pass when it finishes.
  Future<void> build({bool force = false}) async {
    final root = _rootPath;
    if (root == null) return;
    if (_busy) {
      _pendingBuild = true;
      _pendingForce = _pendingForce || force;
      return;
    }
    final gen = ++_gen;
    _busy = true;
    _pendingBuild = false;
    final useForce = force || _pendingForce;
    _pendingForce = false;
    _embedError = null;
    _status = 'Scanning files…';
    _progressDone = 0;
    _progressTotal = 0;
    notifyListeners();

    try {
      final modelChanged =
          _embedModel != null && _embedModel != ollama.embedModel;
      if (useForce || modelChanged) {
        _files = {};
        _chunks = [];
      }

      final found = <String, File>{};
      await _collect(Directory(root), root, found, 0);
      if (gen != _gen) return;

      final byPath = <String, List<CodeChunk>>{};
      for (final c in _chunks) {
        (byPath[c.path] ??= []).add(c);
      }

      final nextFiles = <String, _FileMeta>{};
      final nextChunks = <CodeChunk>[];
      var scanned = 0;
      for (final entry in found.entries) {
        if (gen != _gen) return;
        final rel = entry.key;
        try {
          final stat = await entry.value.stat();
          final meta = _FileMeta(stat.modified.millisecondsSinceEpoch, stat.size);
          final old = _files[rel];
          if (old != null &&
              old.mtimeMs == meta.mtimeMs &&
              old.size == meta.size &&
              byPath.containsKey(rel)) {
            nextFiles[rel] = meta;
            nextChunks.addAll(byPath[rel]!);
          } else {
            final content = await entry.value.readAsString();
            nextFiles[rel] = meta;
            nextChunks.addAll(_chunkFile(rel, content));
          }
        } catch (_) {
          // Unreadable or non-UTF8 file — skip it.
        }
        if (++scanned % 50 == 0) {
          _status = 'Scanning files… $scanned/${found.length}';
          notifyListeners();
        }
      }
      if (gen != _gen) return;
      _files = nextFiles;
      _chunks = nextChunks;

      await _embedMissing(gen);
      if (gen != _gen) return;

      _embedModel = hasVectors ? ollama.embedModel : null;
      _status = _readyStatus();
      await _save();
    } catch (e) {
      if (gen != _gen) return;
      _status = 'Index failed: $e';
    } finally {
      if (gen == _gen) {
        _busy = false;
        notifyListeners();
        if (_pendingBuild) {
          final again = _pendingForce;
          _pendingBuild = false;
          _pendingForce = false;
          build(force: again);
        }
      }
    }
  }

  Future<void> _embedMissing(int gen) async {
    final pending = _chunks.where((c) => c.vector == null).toList();
    if (pending.isEmpty) return;
    _progressTotal = pending.length;
    _progressDone = 0;
    for (var i = 0; i < pending.length; i += _embedBatch) {
      if (gen != _gen) return;
      final batch = pending.sublist(i, math.min(i + _embedBatch, pending.length));
      try {
        final vectors = await ollama.embedBatch([
          for (final c in batch) _docPrefix + _embedText(c),
        ]);
        if (gen != _gen) return;
        for (var j = 0; j < batch.length && j < vectors.length; j++) {
          batch[j].vector = _normalize(vectors[j]);
        }
      } catch (e) {
        // No embed model / Ollama offline: keep keyword-only search.
        _embedError = '$e'.replaceFirst('Exception: ', '');
        return;
      }
      _progressDone = math.min(i + _embedBatch, pending.length);
      _status = 'Embedding $_progressDone/$_progressTotal chunks…';
      notifyListeners();
      // Checkpoint big builds so a crash or close doesn't lose everything.
      if ((i ~/ _embedBatch) % 40 == 39) await _save();
    }
  }

  /// Top [k] chunks for [query], hybrid of embeddings and keywords.
  Future<List<RetrievedChunk>> search(String query, {int k = 6}) async {
    if (_chunks.isEmpty) return const [];
    final terms = _queryTerms(query);

    Float32List? qv;
    if (hasVectors) {
      try {
        final v = await ollama.embedBatch([_queryPrefix + query]);
        if (v.isNotEmpty) qv = _normalize(v.first);
      } catch (_) {
        qv = null;
      }
    }

    // IDF for keyword scoring.
    final df = <String, int>{};
    for (final t in terms) {
      df[t] = _chunks.where((c) => c.lower.contains(t)).length;
    }
    final n = _chunks.length;

    final kw = List<double>.filled(n, 0);
    var maxKw = 0.0;
    for (var i = 0; i < n; i++) {
      final c = _chunks[i];
      var s = 0.0;
      for (final t in terms) {
        final d = df[t]!;
        if (d == 0) continue;
        final tf = _countOccurrences(c.lower, t);
        if (tf == 0) continue;
        final idf = math.log(1 + (n - d + 0.5) / (d + 0.5));
        s += idf * (tf * 2.2) / (tf + 1.2);
        if (c.path.toLowerCase().contains(t)) s += idf;
      }
      kw[i] = s;
      if (s > maxKw) maxKw = s;
    }

    final scored = <RetrievedChunk>[];
    for (var i = 0; i < n; i++) {
      final c = _chunks[i];
      final kwNorm = maxKw > 0 ? kw[i] / maxKw : 0.0;
      double score;
      if (qv != null && c.vector != null && c.vector!.length == qv.length) {
        score = _dot(qv, c.vector!) + 0.3 * kwNorm;
      } else {
        score = kwNorm;
      }
      if (score > 0) scored.add(RetrievedChunk(c, score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    // Skip chunks overlapping an already-picked chunk from the same file.
    final picked = <RetrievedChunk>[];
    for (final r in scored) {
      final overlaps = picked.any((x) =>
          x.chunk.path == r.chunk.path &&
          r.chunk.startLine <= x.chunk.endLine &&
          x.chunk.startLine <= r.chunk.endLine);
      if (overlaps) continue;
      picked.add(r);
      if (picked.length >= k) break;
    }
    return picked;
  }

  /// Citations like `lib/main.dart:12` or `lib/main.dart:12-30` in [text]
  /// that point at files in this index.
  List<CitationRef> parseCitations(String text) {
    final re = RegExp(r'([\w./\\-]+\.[A-Za-z0-9]+)(?::|#L| line )(\d+)(?:\s*[-–]\s*L?(\d+))?');
    final out = <CitationRef>[];
    final seen = <String>{};
    for (final m in re.allMatches(text)) {
      var path = m.group(1)!.replaceAll('\\', '/');
      if (path.startsWith('./')) path = path.substring(2);
      if (!containsPath(path)) {
        // Allow absolute paths or bare basenames that map to one file.
        final match = _files.keys.where((f) => path.endsWith(f) || f.endsWith('/$path')).toList();
        if (match.length != 1) continue;
        path = match.first;
      }
      final start = int.parse(m.group(2)!);
      final end = m.group(3) != null ? int.parse(m.group(3)!) : null;
      final ref = CitationRef(
        path: path,
        startLine: start,
        endLine: end != null && end >= start ? end : null,
      );
      if (seen.add(ref.label)) out.add(ref);
    }
    return out;
  }

  String _readyStatus() {
    if (_chunks.isEmpty) return 'Not indexed';
    final mode = hasVectors ? 'semantic' : 'keyword';
    return '$fileCount files · $chunkCount chunks · $mode';
  }

  String get _docPrefix =>
      ollama.embedModel.contains('nomic') ? 'search_document: ' : '';
  String get _queryPrefix =>
      ollama.embedModel.contains('nomic') ? 'search_query: ' : '';

  static String _embedText(CodeChunk c) {
    final body = c.text.length > 4000 ? c.text.substring(0, 4000) : c.text;
    return 'File: ${c.path} (lines ${c.startLine}-${c.endLine})\n$body';
  }

  static List<CodeChunk> _chunkFile(String rel, String content) {
    final lines = const LineSplitter().convert(content);
    final out = <CodeChunk>[];
    for (var start = 0; start < lines.length; start += _chunkStep) {
      final end = math.min(start + _chunkLines, lines.length);
      final text = lines.sublist(start, end).join('\n');
      if (text.trim().isNotEmpty) {
        out.add(CodeChunk(
          path: rel,
          startLine: start + 1,
          endLine: end,
          text: text,
        ));
      }
      if (end >= lines.length) break;
    }
    return out;
  }

  Future<void> _collect(
    Directory dir,
    String root,
    Map<String, File> out,
    int depth,
  ) async {
    if (depth > 10 || out.length >= _maxFiles) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (out.length >= _maxFiles) return;
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_skipDirs.contains(name) || name.startsWith('.')) continue;
          await _collect(entity, root, out, depth + 1);
        } else if (entity is File) {
          if (_skipNames.contains(name) || name.contains('.min.')) continue;
          final ext = p.extension(name).toLowerCase();
          if (!_textExts.contains(ext) && !_textNames.contains(name)) continue;
          if (await entity.length() > _maxFileBytes) continue;
          final rel = p.relative(entity.path, from: root).replaceAll('\\', '/');
          out[rel] = entity;
        }
      }
    } catch (_) {}
  }

  static const _stopWords = {
    'the', 'and', 'for', 'how', 'what', 'where', 'why', 'does', 'is', 'are',
    'this', 'that', 'with', 'from', 'into', 'can', 'you', 'code', 'file',
    'use', 'used', 'which', 'when', 'who', 'do', 'in', 'of', 'to', 'a', 'an',
    'it', 'on', 'be', 'or', 'me', 'my', 'show', 'find', 'explain', 'about',
  };

  static List<String> _queryTerms(String query) {
    final terms = <String>{};
    for (final m in RegExp(r'[A-Za-z_][A-Za-z0-9_]*').allMatches(query)) {
      final word = m.group(0)!;
      final lower = word.toLowerCase();
      if (lower.length >= 2 && !_stopWords.contains(lower)) terms.add(lower);
      // Also split camelCase / snake_case identifiers.
      for (final part in word
          .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
          .split(RegExp(r'[_\s]+'))) {
        final pl = part.toLowerCase();
        if (pl.length >= 3 && !_stopWords.contains(pl)) terms.add(pl);
      }
    }
    return terms.toList();
  }

  static int _countOccurrences(String haystack, String needle) {
    var count = 0;
    var i = haystack.indexOf(needle);
    while (i != -1 && count < 20) {
      count++;
      i = haystack.indexOf(needle, i + needle.length);
    }
    return count;
  }

  static Float32List _normalize(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = sum > 0 ? math.sqrt(sum) : 1.0;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  static double _dot(Float32List a, Float32List b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  Future<void> _save() async {
    final root = _rootPath;
    if (root == null) return;
    try {
      final file = await AppStorage.workspaceFile('rag_index', root);
      final files = Map.of(_files);
      final chunks = List.of(_chunks);
      final embedModel = hasVectors ? ollama.embedModel : null;
      final json = await Isolate.run(
        () => _encode(root, embedModel, files, chunks),
      );
      await AppStorage.writeAtomic(file, json);
    } catch (_) {
      // Persisting is best-effort; the in-memory index still works.
    }
  }

  static String _encode(
    String root,
    String? embedModel,
    Map<String, _FileMeta> files,
    List<CodeChunk> chunks,
  ) {
    return jsonEncode({
      'version': _formatVersion,
      'root': root,
      'embedModel': embedModel,
      'files': {
        for (final e in files.entries) e.key: [e.value.mtimeMs, e.value.size],
      },
      'chunks': [
        for (final c in chunks)
          {
            'p': c.path,
            's': c.startLine,
            'e': c.endLine,
            't': c.text,
            if (c.vector != null)
              'v': base64Encode(c.vector!.buffer.asUint8List(
                c.vector!.offsetInBytes,
                c.vector!.lengthInBytes,
              )),
          },
      ],
    });
  }

  static _StoredIndex? _decode(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['version'] != _formatVersion) return null;
    final files = <String, _FileMeta>{
      for (final e in (data['files'] as Map<String, dynamic>).entries)
        e.key: _FileMeta(
          (e.value as List<dynamic>)[0] as int,
          (e.value as List<dynamic>)[1] as int,
        ),
    };
    final chunks = <CodeChunk>[
      for (final c in data['chunks'] as List<dynamic>)
        _decodeChunk(c as Map<String, dynamic>),
    ];
    return _StoredIndex(data['embedModel'] as String?, files, chunks);
  }

  static CodeChunk _decodeChunk(Map<String, dynamic> c) {
    final v = c['v'] as String?;
    Float32List? vector;
    if (v != null) {
      final bytes = base64Decode(v);
      vector = Float32List.view(
        Uint8List.fromList(bytes).buffer,
        0,
        bytes.length ~/ 4,
      );
    }
    return CodeChunk(
      path: c['p'] as String,
      startLine: c['s'] as int,
      endLine: c['e'] as int,
      text: c['t'] as String,
      vector: vector,
    );
  }
}
