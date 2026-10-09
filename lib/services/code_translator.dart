import 'package:path/path.dart' as p;

import 'ollama_service.dart';

/// How a translation is verified after it is written.
enum TranslationCheck { testsMatch, tsc }

enum TranslationKind {
  jsToPython('JavaScript → Python', 'JavaScript', 'Python', TranslationCheck.testsMatch),
  pythonToJs('Python → JavaScript', 'Python', 'JavaScript', TranslationCheck.testsMatch),
  jsToTs('JavaScript → TypeScript', 'JavaScript', 'TypeScript', TranslationCheck.tsc);

  const TranslationKind(this.label, this.from, this.to, this.check);

  final String label;
  final String from;
  final String to;
  final TranslationCheck check;

  static const _jsExts = {'.js', '.mjs', '.cjs', '.jsx'};

  /// Conversions offered for a source file, best first.
  static List<TranslationKind> forPath(String? path) {
    if (path == null) return const [];
    final ext = p.extension(path).toLowerCase();
    if (_jsExts.contains(ext)) {
      // JSX is UI code: a Python port can't be run side by side.
      return ext == '.jsx' ? const [jsToTs] : const [jsToTs, jsToPython];
    }
    if (ext == '.py') return const [pythonToJs];
    return const [];
  }

  /// Where the translation is written: next to the source, new extension.
  String targetPath(String sourcePath) {
    final ext = p.extension(sourcePath).toLowerCase();
    final stem = p.withoutExtension(sourcePath);
    switch (this) {
      case jsToPython:
        // Python modules can't contain '-' or '.', so normalise the name.
        final base = p.basename(stem).replaceAll(RegExp(r'[^\w]'), '_');
        return p.join(p.dirname(sourcePath), '$base.py');
      case pythonToJs:
        return '$stem.js';
      case jsToTs:
        return ext == '.jsx' ? '$stem.tsx' : '$stem.ts';
    }
  }

  String get fenceTag => switch (this) {
        jsToPython => 'python',
        pythonToJs => 'javascript',
        jsToTs => 'typescript',
      };

  String get _rules => switch (this) {
        jsToPython => '- Keep every top-level function; use snake_case names.\n'
            '- Use only the Python 3 standard library.\n'
            '- Return the same values the JavaScript returns (null → None, arrays → lists, objects → dicts).\n'
            '- Do not add a __main__ block or example calls.',
        pythonToJs => '- Keep every top-level function; use camelCase names.\n'
            '- Use modern ES module syntax and `export` each top-level function.\n'
            '- No npm packages; Node built-ins only.\n'
            '- Return the same values the Python returns (None → null, tuples → arrays, dicts → objects).\n'
            '- Do not add example calls.',
        jsToTs => '- Add explicit parameter and return types; declare interfaces/types for object shapes.\n'
            '- Avoid `any`; use `unknown` plus narrowing when the type is genuinely open.\n'
            '- Keep names, exports and runtime behavior identical.\n'
            '- Convert require/module.exports to import/export.',
      };

  List<ChatMessage> prompt(String source, String sourcePath) => [
        ChatMessage(
          role: 'system',
          content: 'You are a precise code translator. Translate $from to '
              'idiomatic $to with exactly the same behavior.\n$_rules\n'
              'Reply with ONLY the complete translated file in one ```$fenceTag code block.',
        ),
        ChatMessage(
          role: 'user',
          content: 'File: ${p.basename(sourcePath)}\n\n```\n$source\n```',
        ),
      ];

  /// Follow-up prompt that feeds failed checks back to the model.
  List<ChatMessage> repairPrompt(
    String source,
    String sourcePath,
    String translated,
    String feedback,
  ) =>
      [
        ...prompt(source, sourcePath),
        ChatMessage(role: 'assistant', content: '```$fenceTag\n$translated\n```'),
        ChatMessage(
          role: 'user',
          content: 'The translation fails these checks:\n\n$feedback\n\n'
              'Fix it. Reply with ONLY the complete corrected file in one ```$fenceTag code block.',
        ),
      ];
}

class CodeTranslator {
  CodeTranslator(this.ollama);

  final OllamaService ollama;

  Future<String> translate(
    TranslationKind kind,
    String source,
    String sourcePath, {
    String? model,
  }) async {
    final reply = await ollama.chat(
      messages: kind.prompt(source, sourcePath),
      model: model,
    );
    return extractCode(reply);
  }

  Future<String> repair(
    TranslationKind kind,
    String source,
    String sourcePath,
    String translated,
    String feedback, {
    String? model,
  }) async {
    final reply = await ollama.chat(
      messages: kind.repairPrompt(source, sourcePath, translated, feedback),
      model: model,
    );
    return extractCode(reply);
  }

  /// Largest fenced block in [reply], or the whole reply when unfenced.
  static String extractCode(String reply) {
    final re = RegExp(r'```[^\n`]*\n([\s\S]*?)```');
    var best = '';
    for (final m in re.allMatches(reply)) {
      final body = m.group(1) ?? '';
      if (body.length > best.length) best = body;
    }
    if (best.trim().isEmpty) {
      // Unterminated fence (model hit its length limit).
      final open = RegExp(r'```[^\n`]*\n([\s\S]*)$').firstMatch(reply);
      best = open?.group(1) ?? reply;
    }
    best = best.trimRight();
    return best.isEmpty ? '' : '$best\n';
  }
}
