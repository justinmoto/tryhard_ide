import 'dart:io';

import 'package:path/path.dart' as p;

class FileResolver {
  static const _skipDirs = {
    '.git',
    '.dart_tool',
    'build',
    'node_modules',
    '.idea',
    '.vscode',
    'Pods',
    'coverage',
    'dist',
    '.next',
  };

  /// Resolve a relative/absolute path or basename under [rootPath].
  static Future<String?> resolve({
    required String? rootPath,
    required String? hint,
    String? openPath,
    String? userPrompt,
  }) async {
    if (hint != null && hint.trim().isNotEmpty) {
      final resolved = await _resolveHint(rootPath, hint.trim());
      if (resolved != null) return resolved;
    }

    final fromPrompt = _hintsFromPrompt(userPrompt ?? '');
    for (final h in fromPrompt) {
      final resolved = await _resolveHint(rootPath, h);
      if (resolved != null) return resolved;
    }

    if (openPath != null && openPath.isNotEmpty) {
      final f = File(openPath);
      if (await f.exists()) return openPath;
    }

    // Common Flutter/web defaults
    if (rootPath != null) {
      for (final rel in ['lib/main.dart', 'src/main.dart', 'main.dart', 'index.js', 'App.tsx']) {
        final candidate = p.join(rootPath, rel);
        if (await File(candidate).exists()) return candidate;
      }
    }

    return null;
  }

  static Future<String?> _resolveHint(String? rootPath, String hint) async {
    var cleaned = hint
        .replaceAll('`', '')
        .replaceAll('"', '')
        .replaceAll("'", '')
        .trim();
    if (cleaned.startsWith('file:')) {
      cleaned = cleaned.substring(5).trim();
    }

    if (p.isAbsolute(cleaned)) {
      if (await File(cleaned).exists()) return cleaned;
    }

    if (rootPath != null) {
      final joined = p.normalize(p.join(rootPath, cleaned));
      if (await File(joined).exists()) return joined;

      // Basename search
      final base = p.basename(cleaned);
      if (base.isNotEmpty && base.contains('.')) {
        final found = await findByBasename(rootPath, base);
        if (found != null) return found;
      }
    }

    return null;
  }

  static List<String> _hintsFromPrompt(String prompt) {
    final out = <String>[];
    final pathRe = RegExp(
      r'''(?:^|[\s`"'(])((?:[\w.-]+/)*[\w.-]+\.(?:dart|js|jsx|ts|tsx|py|json|html|css|md|yaml|yml|sql))''',
      caseSensitive: false,
    );
    for (final m in pathRe.allMatches(prompt)) {
      out.add(m.group(1)!);
    }
    final lower = prompt.toLowerCase();
    if (lower.contains('main dart') || lower.contains('main.dart')) {
      out.add('lib/main.dart');
      out.add('main.dart');
    }
    return out;
  }

  static Future<String?> findByBasename(String rootPath, String basename) async {
    final matches = <String>[];
    await _walk(Directory(rootPath), basename, matches, 0);
    if (matches.isEmpty) return null;
    // Prefer lib/ and shorter paths
    matches.sort((a, b) {
      final ap = a.contains('${p.separator}lib${p.separator}') ? 0 : 1;
      final bp = b.contains('${p.separator}lib${p.separator}') ? 0 : 1;
      if (ap != bp) return ap - bp;
      return a.length.compareTo(b.length);
    });
    return matches.first;
  }

  static Future<void> _walk(
    Directory dir,
    String basename,
    List<String> out,
    int depth,
  ) async {
    if (depth > 8 || out.length >= 20) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_skipDirs.contains(name) || name.startsWith('.')) continue;
          await _walk(entity, basename, out, depth + 1);
        } else if (entity is File && name == basename) {
          out.add(entity.path);
        }
      }
    } catch (_) {}
  }

  static Future<List<String>> listProjectFiles(String? rootPath, {int limit = 40}) async {
    if (rootPath == null) return const [];
    final out = <String>[];
    await _collect(Directory(rootPath), rootPath, out, 0, limit);
    return out;
  }

  /// Find files whose relative path or basename contains [query].
  /// Returns absolute paths, best matches first (max [limit]).
  static Future<List<String>> searchByName(
    String? rootPath,
    String query, {
    int limit = 40,
  }) async {
    if (rootPath == null) return const [];
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final scored = <({String path, int score})>[];
    await _collectNamed(Directory(rootPath), rootPath, q, scored, 0);
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.path.compareTo(b.path);
    });
    return [
      for (final s in scored.take(limit)) s.path,
    ];
  }

  static Future<void> _collectNamed(
    Directory dir,
    String root,
    String query,
    List<({String path, int score})> out,
    int depth,
  ) async {
    if (depth > 8 || out.length >= 200) return;
    try {
      final entities = await dir.list(followLinks: false).toList();
      for (final entity in entities) {
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_skipDirs.contains(name) || name.startsWith('.')) continue;
          await _collectNamed(entity, root, query, out, depth + 1);
        } else if (entity is File) {
          final rel = p.relative(entity.path, from: root);
          final relLower = rel.toLowerCase();
          final baseLower = name.toLowerCase();
          if (!relLower.contains(query) && !baseLower.contains(query)) {
            continue;
          }
          var score = 0;
          if (baseLower == query) {
            score = 100;
          } else if (baseLower.startsWith(query)) {
            score = 80;
          } else if (baseLower.contains(query)) {
            score = 60;
          } else if (relLower.startsWith(query)) {
            score = 40;
          } else {
            score = 20;
          }
          // Prefer shorter paths when scores tie later.
          score -= (rel.length / 50).floor().clamp(0, 10);
          out.add((path: entity.path, score: score));
        }
      }
    } catch (_) {}
  }

  static Future<void> _collect(
    Directory dir,
    String root,
    List<String> out,
    int depth,
    int limit,
  ) async {
    if (depth > 5 || out.length >= limit) return;
    try {
      final entities = await dir.list(followLinks: false).toList();
      entities.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entities) {
        if (out.length >= limit) return;
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (_skipDirs.contains(name) || name.startsWith('.')) continue;
          await _collect(entity, root, out, depth + 1, limit);
        } else if (entity is File) {
          final ext = p.extension(name).toLowerCase();
          if ({'.dart', '.js', '.jsx', '.ts', '.tsx', '.py', '.json', '.md', '.html', '.css'}
              .contains(ext)) {
            out.add(p.relative(entity.path, from: root));
          }
        }
      }
    } catch (_) {}
  }
}
