import 'package:flutter/services.dart';

enum EditScope { selection, file, searchReplace }

class EditProposal {
  const EditProposal({
    required this.scope,
    required this.newText,
    this.oldText,
    this.summary,
    this.targetHint,
  });

  final EditScope scope;
  final String newText;
  final String? oldText;
  final String? summary;
  final String? targetHint;

  EditProposal copyWith({String? targetHint}) {
    return EditProposal(
      scope: scope,
      newText: newText,
      oldText: oldText,
      summary: summary,
      targetHint: targetHint ?? this.targetHint,
    );
  }

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
    final pathHint = extractPathHint(reply);

    final block = _parseEditBlock(reply);
    if (block != null) {
      final oldText = block.$1;
      final newText = block.$2;
      EditProposal proposal;
      if (oldText != null && oldText.trim().isNotEmpty) {
        proposal = EditProposal(
          scope: EditScope.searchReplace,
          oldText: oldText,
          newText: newText,
          summary: 'Search/replace edit',
          targetHint: pathHint,
        );
      } else if (selection.isNotEmpty && !preferFileReplace) {
        proposal = EditProposal(
          scope: EditScope.selection,
          oldText: selection,
          newText: newText,
          summary: 'Replace selection',
          targetHint: pathHint,
        );
      } else {
        proposal = EditProposal(
          scope: EditScope.file,
          newText: newText,
          summary: 'Replace file',
          targetHint: pathHint,
        );
      }
      return proposal;
    }

    final fence = _largestCodeFence(reply);
    if (fence != null) {
      return _fromCode(
        fence.code,
        fileContent,
        selection,
        preferFileReplace,
        pathHint ?? fence.pathHint,
      );
    }

    return null;
  }

  static String? extractPathHint(String reply) {
    final fileLine = RegExp(
      r'^(?:Changed|File|FILE|Path)\s*:\s*([^\s]+)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(reply);
    if (fileLine != null) {
      return fileLine
          .group(1)!
          .replaceAll('`', '')
          .replaceAll('"', '')
          .replaceAll("'", '');
    }

    final fence = _largestCodeFence(reply);
    return fence?.pathHint;
  }

  static EditProposal _fromCode(
    String code,
    String fileContent,
    String selection,
    bool preferFileReplace,
    String? pathHint,
  ) {
    var body = code;
    // Allow first line: // FILE: lib/main.dart
    final fileComment = RegExp(
      r'''^\s*(?://|#|--)\s*FILE\s*:\s*([^\n]+)''',
      caseSensitive: false,
    ).firstMatch(body);
    if (fileComment != null) {
      pathHint ??= fileComment.group(1)?.trim();
      body = body.substring(fileComment.end).replaceFirst(RegExp(r'^\n'), '');
    }

    final normalized = body.endsWith('\n') ? body : '$body\n';

    if (selection.trim().isEmpty || preferFileReplace) {
      return EditProposal(
        scope: EditScope.file,
        newText: normalized,
        summary: 'Replace entire file',
        targetHint: pathHint,
      );
    }

    final looksFullFile = _looksLikeFullFile(body) ||
        body.length >= (fileContent.length * 0.35).clamp(80, 100000).toInt();

    if (looksFullFile) {
      return EditProposal(
        scope: EditScope.file,
        newText: normalized,
        summary: 'Replace entire file',
        targetHint: pathHint,
      );
    }

    return EditProposal(
      scope: EditScope.selection,
      oldText: selection,
      newText: body,
      summary: 'Replace selection',
      targetHint: pathHint,
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

  static ({String code, String? pathHint})? _largestCodeFence(String reply) {
    // ```dart:lib/main.dart or ```lib/main.dart or ```dart
    final re = RegExp(r'```([^\n`]*)\n([\s\S]*?)```');
    String? bestCode;
    String? bestHint;
    var bestLen = -1;
    for (final m in re.allMatches(reply)) {
      final tag = (m.group(1) ?? '').trim();
      final body = (m.group(2) ?? '').trimRight();
      if (body.trim().length < 15) continue;
      if (body.length > bestLen) {
        bestLen = body.length;
        bestCode = body;
        bestHint = _pathFromFenceTag(tag);
      }
    }
    if (bestCode == null) return null;
    return (code: bestCode, pathHint: bestHint);
  }

  static String? _pathFromFenceTag(String tag) {
    if (tag.isEmpty) return null;
    // dart:lib/main.dart | tsx:src/App.tsx | lib/main.dart
    if (tag.contains('/') || tag.contains('.')) {
      final idx = tag.indexOf(':');
      if (idx > 0 && idx < tag.length - 1) {
        final after = tag.substring(idx + 1).trim();
        if (after.contains('/') || after.contains('.')) return after;
      }
      if (tag.contains('.')) return tag;
    }
    return null;
  }
}
