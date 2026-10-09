import 'package:flutter/services.dart';

enum EditScope { selection, file, searchReplace }

class EditProposal {
  const EditProposal({
    required this.scope,
    required this.newText,
    this.oldText,
    this.summary,
  });

  final EditScope scope;
  final String newText;
  final String? oldText;
  final String? summary;

  /// Returns updated file contents, or null if apply failed.
  String? applyTo(String fileContent, {TextSelection? selection}) {
    switch (scope) {
      case EditScope.selection:
        if (oldText != null && oldText!.isNotEmpty) {
          final replaced = _replaceOnce(fileContent, oldText!, newText);
          if (replaced != null) return replaced;
        }
        if (selection == null || !selection.isValid || selection.isCollapsed) {
          return null;
        }
        return fileContent.replaceRange(selection.start, selection.end, newText);

      case EditScope.file:
        return newText;

      case EditScope.searchReplace:
        final needle = oldText ?? '';
        if (needle.isEmpty) return null;
        return _replaceOnce(fileContent, needle, newText);
    }
  }

  static String? _replaceOnce(String source, String from, String to) {
    final index = source.indexOf(from);
    if (index < 0) {
      final normSource = source.replaceAll('\r\n', '\n');
      final normFrom = from.replaceAll('\r\n', '\n');
      final i = normSource.indexOf(normFrom);
      if (i < 0) return null;
      return normSource.replaceRange(i, i + normFrom.length, to);
    }
    return source.replaceRange(index, index + from.length, to);
  }

  static EditProposal? parse(
    String reply, {
    required String fileContent,
    required String selection,
    bool preferFileReplace = false,
  }) {
    final block = _parseEditBlock(reply);
    if (block != null) {
      final oldText = block.$1;
      final newText = block.$2;
      if (oldText != null && oldText.trim().isNotEmpty) {
        return EditProposal(
          scope: EditScope.searchReplace,
          oldText: oldText,
          newText: newText,
          summary: 'Search/replace edit',
        );
      }
      if (selection.isNotEmpty && !preferFileReplace) {
        return EditProposal(
          scope: EditScope.selection,
          oldText: selection,
          newText: newText,
          summary: 'Replace selection',
        );
      }
      return EditProposal(
        scope: EditScope.file,
        newText: newText,
        summary: 'Replace file',
      );
    }

    final labeled = _parseFence(
      reply,
      const ['replace', 'suggestion', 'edit', 'file'],
    );
    if (labeled != null) {
      return _fromCode(labeled, fileContent, selection, preferFileReplace);
    }

    // Models often return ```dart / ```js — take the largest fence.
    final anyFence = _largestCodeFence(reply);
    if (anyFence != null) {
      return _fromCode(anyFence, fileContent, selection, preferFileReplace);
    }

    return null;
  }

  static EditProposal _fromCode(
    String code,
    String fileContent,
    String selection,
    bool preferFileReplace,
  ) {
    final normalized = code.endsWith('\n') ? code : '$code\n';

    // No selection → always write the whole open file (never fail apply).
    if (selection.trim().isEmpty || preferFileReplace) {
      return EditProposal(
        scope: EditScope.file,
        newText: normalized,
        summary: 'Replace entire file',
      );
    }

    final looksFullFile = _looksLikeFullFile(code) ||
        code.length >= (fileContent.length * 0.35).clamp(80, 100000).toInt();

    if (looksFullFile) {
      return EditProposal(
        scope: EditScope.file,
        newText: normalized,
        summary: 'Replace entire file',
      );
    }

    return EditProposal(
      scope: EditScope.selection,
      oldText: selection,
      newText: code,
      summary: 'Replace selection',
    );
  }

  static bool _looksLikeFullFile(String code) {
    final t = code.trimLeft();
    if (t.startsWith('import ') ||
        t.startsWith('export ') ||
        t.startsWith('package ') ||
        t.startsWith('#!') ||
        t.startsWith('<?') ||
        t.startsWith('<!DOCTYPE') ||
        t.startsWith('<html')) {
      return true;
    }
    if (t.contains('void main(') || t.contains('Future<void> main(')) {
      return true;
    }
    if (RegExp(r'\b(class|function|def)\s+\w+').allMatches(t).length >= 2) {
      return true;
    }
    return false;
  }

  static (String?, String)? _parseEditBlock(String reply) {
    final patterns = <RegExp>[
      RegExp(
        r'<<<EDIT\s*\n([\s\S]*?)\n===\s*\n([\s\S]*?)\nEDIT>>>',
        multiLine: true,
      ),
      RegExp(
        r'<<<<<<< SEARCH\s*\n([\s\S]*?)\n=======\s*\n([\s\S]*?)\n>>>>>>> REPLACE',
        multiLine: true,
      ),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(reply);
      if (m != null) {
        return (m.group(1), m.group(2) ?? '');
      }
    }
    return null;
  }

  static String? _parseFence(String reply, List<String> labels) {
    final label = labels.map(RegExp.escape).join('|');
    final re = RegExp(
      '```(?:$label)\\s*\\n([\\s\\S]*?)\\n```',
      caseSensitive: false,
    );
    final m = re.firstMatch(reply);
    return m?.group(1);
  }

  static String? _largestCodeFence(String reply) {
    final re = RegExp(r'```([a-zA-Z0-9_+-]*)\s*\n([\s\S]*?)```');
    String? best;
    for (final m in re.allMatches(reply)) {
      final body = (m.group(2) ?? '').trimRight();
      if (body.trim().length < 15) continue;
      if (best == null || body.length > best.length) best = body;
    }
    return best;
  }
}
