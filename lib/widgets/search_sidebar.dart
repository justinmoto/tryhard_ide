import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/cursor_theme.dart';
import 'top_toast.dart';

class SearchHit {
  const SearchHit({
    required this.path,
    required this.line,
    required this.column,
    required this.preview,
    required this.matchStart,
    required this.matchLength,
  });

  final String path;
  final int line;
  final int column;
  final String preview;
  final int matchStart;
  final int matchLength;
}

class SearchSidebar extends StatefulWidget {
  const SearchSidebar({
    super.key,
    required this.rootPath,
    required this.onOpenFile,
  });

  final String? rootPath;
  final ValueChanged<String> onOpenFile;

  @override
  State<SearchSidebar> createState() => _SearchSidebarState();
}

class _SearchSidebarState extends State<SearchSidebar> {
  final _search = TextEditingController();
  final _replace = TextEditingController();
  final _include = TextEditingController();
  final _exclude = TextEditingController(
    text: '**/node_modules,**/build,**/.git,**/.dart_tool',
  );

  bool _matchCase = false;
  bool _wholeWord = false;
  bool _useRegex = false;
  bool _preserveCase = false;
  bool _showFilters = true;
  bool _replaceOpen = true;
  bool _searching = false;

  List<SearchHit> _hits = const [];
  String? _error;
  final _expandedFiles = <String>{};

  static const _textExts = {
    '.dart', '.js', '.jsx', '.ts', '.tsx', '.json', '.md', '.txt', '.yaml',
    '.yml', '.html', '.css', '.scss', '.less', '.xml', '.svg', '.py', '.rb',
    '.go', '.rs', '.java', '.kt', '.swift', '.c', '.cpp', '.h', '.hpp',
    '.cs', '.php', '.sh', '.bash', '.zsh', '.env', '.gitignore', '.toml',
    '.ini', '.cfg', '.conf', '.sql', '.vue', '.svelte', '.gradle',
    '.m', '.mm', '.plist', '.lock', '.xib', '.storyboard', '.pbxproj',
  };

  @override
  void dispose() {
    _search.dispose();
    _replace.dispose();
    _include.dispose();
    _exclude.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _search.text;
    final root = widget.rootPath;
    if (root == null) {
      setState(() {
        _hits = const [];
        _error = 'Open a folder to search.';
      });
      return;
    }
    if (query.isEmpty) {
      setState(() {
        _hits = const [];
        _error = null;
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final pattern = _buildPattern(query);
      if (pattern == null) {
        setState(() {
          _searching = false;
          _hits = const [];
          _error = 'Invalid regular expression.';
        });
        return;
      }

      final include = _parseGlobs(_include.text);
      final exclude = _parseGlobs(_exclude.text);
      final hits = <SearchHit>[];
      await _walk(Directory(root), root, pattern, include, exclude, hits);

      setState(() {
        _hits = hits;
        _searching = false;
        _expandedFiles
          ..clear()
          ..addAll(hits.map((h) => h.path).toSet());
      });
    } catch (e) {
      setState(() {
        _searching = false;
        _error = '$e';
      });
    }
  }

  void _clearResults() {
    setState(() {
      _hits = const [];
      _error = null;
      _expandedFiles.clear();
    });
  }

  void _collapseAll() {
    setState(_expandedFiles.clear);
  }

  RegExp? _buildPattern(String query) {
    try {
      if (_useRegex) {
        return RegExp(query, caseSensitive: _matchCase, multiLine: true);
      }
      var escaped = RegExp.escape(query);
      if (_wholeWord) escaped = '\\b$escaped\\b';
      return RegExp(escaped, caseSensitive: _matchCase, multiLine: true);
    } catch (_) {
      return null;
    }
  }

  List<String> _parseGlobs(String raw) {
    return raw
        .split(RegExp(r'[,;\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  bool _matchesAnyGlob(String relative, List<String> globs) {
    if (globs.isEmpty) return false;
    for (final glob in globs) {
      if (_globMatch(relative, glob) || _globMatch(p.basename(relative), glob)) {
        return true;
      }
    }
    return false;
  }

  bool _globMatch(String path, String glob) {
    var g = glob.replaceAll('\\', '/');
    final t = path.replaceAll('\\', '/');
    if (g.startsWith('**/')) g = g.substring(3);
    if (g.startsWith('*/')) g = g.substring(2);
    if (g.contains('*')) {
      final parts = g.split('*').where((e) => e.isNotEmpty).toList();
      if (parts.isEmpty) return true;
      var idx = 0;
      for (final part in parts) {
        final found = t.indexOf(part, idx);
        if (found < 0) return false;
        idx = found + part.length;
      }
      return true;
    }
    return t == g || t.endsWith('/$g') || t.contains('/$g/') || t.startsWith('$g/');
  }

  bool _shouldSkipDir(String name) {
    return name == 'node_modules' ||
        name == '.git' ||
        name == 'build' ||
        name == '.dart_tool' ||
        name == 'Pods' ||
        name == '.idea' ||
        name == 'dist' ||
        name == 'coverage';
  }

  Future<void> _walk(
    Directory dir,
    String root,
    RegExp pattern,
    List<String> include,
    List<String> exclude,
    List<SearchHit> hits,
  ) async {
    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }

    for (final entity in entities) {
      final name = p.basename(entity.path);
      final rel = p.relative(entity.path, from: root).replaceAll('\\', '/');

      if (entity is Directory) {
        if (_shouldSkipDir(name)) continue;
        if (_matchesAnyGlob(rel, exclude) || _matchesAnyGlob('$rel/', exclude)) {
          continue;
        }
        await _walk(entity, root, pattern, include, exclude, hits);
        continue;
      }

      if (entity is! File) continue;
      if (_matchesAnyGlob(rel, exclude)) continue;
      if (include.isNotEmpty && !_matchesAnyGlob(rel, include)) continue;

      final ext = p.extension(name).toLowerCase();
      if (ext.isNotEmpty && !_textExts.contains(ext)) {
        if (name != 'Dockerfile' && name != 'Makefile' && name != 'Podfile') {
          continue;
        }
      }

      try {
        final bytes = await entity.openRead(0, 512).first;
        if (bytes.any((b) => b == 0)) continue;
      } catch (_) {}

      String content;
      try {
        content = await entity.readAsString();
      } catch (_) {
        continue;
      }
      if (content.length > 2 * 1024 * 1024) continue;

      final lines = content.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        for (final match in pattern.allMatches(line)) {
          hits.add(
            SearchHit(
              path: entity.path,
              line: i + 1,
              column: match.start + 1,
              preview: line.trimRight(),
              matchStart: match.start,
              matchLength: match.end - match.start,
            ),
          );
          if (hits.length >= 2000) return;
        }
      }
    }
  }

  Future<void> _replaceAll() async {
    final query = _search.text;
    final replacement = _replace.text;
    if (query.isEmpty || widget.rootPath == null || _hits.isEmpty) return;
    final pattern = _buildPattern(query);
    if (pattern == null) return;

    final files = _hits.map((h) => h.path).toSet();
    var filesChanged = 0;
    for (final path in files) {
      try {
        final file = File(path);
        final content = await file.readAsString();
        final next = content.replaceAllMapped(pattern, (m) {
          if (!_preserveCase) return replacement;
          final original = m[0]!;
          if (original.toUpperCase() == original) return replacement.toUpperCase();
          if (original.toLowerCase() == original) return replacement.toLowerCase();
          if (original.isNotEmpty &&
              original[0].toUpperCase() == original[0]) {
            if (replacement.isEmpty) return replacement;
            return replacement[0].toUpperCase() +
                (replacement.length > 1 ? replacement.substring(1).toLowerCase() : '');
          }
          return replacement;
        });
        if (next != content) {
          await file.writeAsString(next);
          filesChanged++;
        }
      } catch (_) {}
    }

    if (!mounted) return;
    showTopToast(context, 'Replaced in $filesChanged file(s)');
    await _runSearch();
  }

  Map<String, List<SearchHit>> get _grouped {
    final map = <String, List<SearchHit>>{};
    for (final hit in _hits) {
      map.putIfAbsent(hit.path, () => []).add(hit);
    }
    return map;
  }

  Color _fileIconColor(String name) {
    final ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.dart':
        return const Color(0xFF00B4AB);
      case '.js':
      case '.jsx':
      case '.ts':
      case '.tsx':
        return const Color(0xFF519ABA);
      case '.json':
        return const Color(0xFFCBCB41);
      case '.md':
        return const Color(0xFF519ABA);
      case '.xml':
      case '.xib':
      case '.plist':
        return const Color(0xFFE37933);
      case '.yaml':
      case '.yml':
        return const Color(0xFFCB171E);
      default:
        if (name == 'Podfile') return const Color(0xFFCB171E);
        return CursorColors.fgMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped;
    final root = widget.rootPath;
    final fileCount = grouped.length;

    return ColoredBox(
      color: CursorColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 35,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 6),
              child: Row(
                children: [
                  Text(
                    'SEARCH',
                    style: TextStyle(
                      color: CursorColors.fg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const Spacer(),
                  _HeaderBtn(Icons.refresh, 'Refresh', _searching ? null : _runSearch),
                  _HeaderBtn(Icons.clear_all, 'Clear Search Results', _clearResults),
                  _HeaderBtn(Icons.note_add_outlined, 'Open New Search Editor', () {}),
                  _HeaderBtn(Icons.view_list_outlined, 'View as List', () {}),
                  _HeaderBtn(Icons.unfold_less, 'Collapse All', _collapseAll),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 8, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => setState(() => _replaceOpen = !_replaceOpen),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6, right: 2),
                    child: Icon(
                      _replaceOpen
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: CursorColors.fgMuted,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      _SearchField(
                        controller: _search,
                        hint: 'Search',
                        onSubmitted: (_) => _runSearch(),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Toggle(
                              label: 'Aa',
                              tooltip: 'Match Case',
                              active: _matchCase,
                              onTap: () => setState(() => _matchCase = !_matchCase),
                            ),
                            _Toggle(
                              label: 'ab',
                              tooltip: 'Match Whole Word',
                              active: _wholeWord,
                              underline: true,
                              onTap: () => setState(() => _wholeWord = !_wholeWord),
                            ),
                            _Toggle(
                              label: '.*',
                              tooltip: 'Use Regular Expression',
                              active: _useRegex,
                              onTap: () => setState(() => _useRegex = !_useRegex),
                            ),
                          ],
                        ),
                      ),
                      if (_replaceOpen) ...[
                        SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: _SearchField(
                                controller: _replace,
                                hint: 'Replace',
                                onSubmitted: (_) => _replaceAll(),
                                trailing: _Toggle(
                                  label: 'AB',
                                  tooltip: 'Preserve Case',
                                  active: _preserveCase,
                                  onTap: () => setState(
                                    () => _preserveCase = !_preserveCase,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: 2),
                            _HeaderBtn(
                              Icons.find_replace,
                              'Replace All',
                              _hits.isEmpty ? null : _replaceAll,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 6, 2),
            child: Align(
              alignment: Alignment.centerRight,
              child: _HeaderBtn(
                Icons.more_horiz,
                'Toggle Search Details',
                () => setState(() => _showFilters = !_showFilters),
              ),
            ),
          ),
          if (_showFilters)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'files to include',
                    style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
                  ),
                  SizedBox(height: 3),
                  _SearchField(
                    controller: _include,
                    hint: '',
                    onSubmitted: (_) => _runSearch(),
                    trailing: Icon(
                      Icons.menu_book_outlined,
                      size: 14,
                      color: CursorColors.fgDim,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'files to exclude',
                    style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
                  ),
                  SizedBox(height: 3),
                  _SearchField(
                    controller: _exclude,
                    hint: '',
                    onSubmitted: (_) => _runSearch(),
                    trailing: Icon(
                      Icons.settings_outlined,
                      size: 14,
                      color: CursorColors.fgDim,
                    ),
                  ),
                ],
              ),
            ),
          if (_searching || _error != null || _hits.isNotEmpty || _search.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 12, 6),
              child: _searching
                  ? Text(
                      'Searching…',
                      style: TextStyle(color: CursorColors.fgDim, fontSize: 12),
                    )
                  : _error != null
                      ? Text(
                          _error!,
                          style: TextStyle(color: CursorColors.statusOffline, fontSize: 12),
                        )
                      : _hits.isEmpty
                          ? Text(
                              root == null
                                  ? 'Open a folder to search'
                                  : 'No results found.',
                              style: TextStyle(color: CursorColors.fgDim, fontSize: 12),
                            )
                          : Text.rich(
                              TextSpan(
                                style: TextStyle(
                                  color: CursorColors.fgMuted,
                                  fontSize: 12,
                                ),
                                children: [
                                  TextSpan(
                                    text:
                                        '${_hits.length} result${_hits.length == 1 ? '' : 's'} in $fileCount file${fileCount == 1 ? '' : 's'}',
                                  ),
                                  const TextSpan(text: ' - '),
                                  TextSpan(
                                    text: 'Open in editor',
                                    style: TextStyle(color: CursorColors.accentSoft),
                                  ),
                                ],
                              ),
                            ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                for (final entry in grouped.entries)
                  _FileGroup(
                    path: entry.key,
                    root: root,
                    hits: entry.value,
                    expanded: _expandedFiles.contains(entry.key),
                    iconColor: _fileIconColor(p.basename(entry.key)),
                    onToggle: () {
                      setState(() {
                        if (!_expandedFiles.remove(entry.key)) {
                          _expandedFiles.add(entry.key);
                        }
                      });
                    },
                    onOpen: () => widget.onOpenFile(entry.key),
                    onOpenHit: (hit) => widget.onOpenFile(hit.path),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileGroup extends StatelessWidget {
  const _FileGroup({
    required this.path,
    required this.root,
    required this.hits,
    required this.expanded,
    required this.iconColor,
    required this.onToggle,
    required this.onOpen,
    required this.onOpenHit,
  });

  final String path;
  final String? root;
  final List<SearchHit> hits;
  final bool expanded;
  final Color iconColor;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final ValueChanged<SearchHit> onOpenHit;

  @override
  Widget build(BuildContext context) {
    final name = p.basename(path);
    final dir = root == null
        ? p.dirname(path)
        : p.relative(p.dirname(path), from: root!).replaceAll('\\', '/');
    final contextLabel = (dir == '.' || dir.isEmpty) ? '' : dir;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          onDoubleTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                  size: 14,
                  color: CursorColors.fgMuted,
                ),
                Icon(Icons.insert_drive_file, size: 14, color: iconColor),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: CursorColors.fg, fontSize: 12),
                  ),
                ),
                if (contextLabel.isNotEmpty) ...[
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      contextLabel,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: CursorColors.fgDim, fontSize: 11),
                    ),
                  ),
                ],
                SizedBox(width: 8),
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: CursorColors.accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${hits.length}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          for (final hit in hits)
            InkWell(
              onTap: () => onOpenHit(hit),
              child: Padding(
                padding: const EdgeInsets.only(left: 34, right: 10, top: 2, bottom: 2),
                child: _HighlightedPreview(hit: hit),
              ),
            ),
      ],
    );
  }
}

class _HighlightedPreview extends StatelessWidget {
  const _HighlightedPreview({required this.hit});

  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final raw = hit.preview;
    var start = hit.matchStart;
    var end = (hit.matchStart + hit.matchLength).clamp(0, raw.length);
    start = start.clamp(0, raw.length);

    // Trim long lines like Cursor: keep context around the match.
    const maxLen = 72;
    var display = raw;
    var matchStart = start;
    var matchEnd = end;
    var prefix = '';
    if (raw.length > maxLen) {
      final left = (start - 20).clamp(0, raw.length);
      display = raw.substring(left);
      if (left > 0) prefix = '…';
      matchStart = start - left;
      matchEnd = end - left;
      if (display.length > maxLen) {
        display = display.substring(0, maxLen);
        if (matchEnd > maxLen) matchEnd = maxLen;
        if (matchStart > maxLen) matchStart = maxLen;
      }
    }

    matchStart = matchStart.clamp(0, display.length);
    matchEnd = matchEnd.clamp(matchStart, display.length);

    return Text.rich(
      TextSpan(
        style: TextStyle(color: CursorColors.fgMuted, fontSize: 12, height: 1.35),
        children: [
          if (prefix.isNotEmpty) TextSpan(text: prefix),
          if (matchStart > 0) TextSpan(text: display.substring(0, matchStart)),
          if (matchEnd > matchStart)
            TextSpan(
              text: display.substring(matchStart, matchEnd),
              style: TextStyle(
                backgroundColor: Color(0xFF3A3D41),
                color: Colors.white,
              ),
            ),
          if (matchEnd < display.length) TextSpan(text: display.substring(matchEnd)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    this.onSubmitted,
    this.trailing,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: CursorColors.input,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: const Color(0xFF3C3C3C)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: TextStyle(color: Colors.white, fontSize: 12),
              cursorColor: CursorColors.accentSoft,
              decoration: InputDecoration(
                isDense: true,
                hintText: hint.isEmpty ? null : hint,
                hintStyle: TextStyle(color: CursorColors.fgDim, fontSize: 12),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              ),
              onSubmitted: onSubmitted,
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: trailing!,
            ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.underline = false,
  });

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  final bool underline;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(2),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF3A3D41) : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
            border: active
                ? Border.all(color: const Color(0xFF007ACC).withValues(alpha: 0.7))
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : CursorColors.fgMuted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              decoration: underline ? TextDecoration.underline : null,
              decorationColor: active ? Colors.white : CursorColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderBtn extends StatelessWidget {
  const _HeaderBtn(this.icon, this.tooltip, this.onTap);

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 15,
            color: onTap == null ? CursorColors.fgDim : CursorColors.fgMuted,
          ),
        ),
      ),
    );
  }
}
