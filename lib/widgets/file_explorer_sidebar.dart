import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/cursor_theme.dart';

class FileExplorerSidebar extends StatefulWidget {
  const FileExplorerSidebar({
    super.key,
    required this.rootPath,
    required this.openPath,
    required this.onOpenFile,
    required this.onPickFolder,
  });

  final String? rootPath;
  final String? openPath;
  final ValueChanged<String> onOpenFile;
  final Future<void> Function() onPickFolder;

  @override
  State<FileExplorerSidebar> createState() => _FileExplorerSidebarState();
}

class _FileExplorerSidebarState extends State<FileExplorerSidebar> {
  final _expanded = <String>{};
  int _refreshToken = 0;

  @override
  void initState() {
    super.initState();
    if (widget.rootPath != null) _expanded.add(widget.rootPath!);
  }

  @override
  void didUpdateWidget(covariant FileExplorerSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath) {
      _expanded.clear();
      if (widget.rootPath != null) _expanded.add(widget.rootPath!);
      _refreshToken++;
    }
  }

  void _toggleExpand(String path) {
    setState(() {
      if (!_expanded.remove(path)) _expanded.add(path);
    });
  }

  List<_FsEntry> _listEntries(String dirPath) {
    try {
      final entities = Directory(dirPath).listSync(followLinks: false);
      final entries = <_FsEntry>[];
      for (final entity in entities) {
        final name = p.basename(entity.path);
        if (name == '.' || name == '..') continue;
        entries.add(
          _FsEntry(
            path: entity.path,
            name: name,
            isDirectory: entity is Directory,
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    } catch (_) {
      return const [];
    }
  }

  List<Widget> _buildTree(String dirPath, int depth) {
    final widgets = <Widget>[];
    for (final entry in _listEntries(dirPath)) {
      final isOpen = widget.openPath == entry.path;
      final isExpanded = _expanded.contains(entry.path);

      final row = InkWell(
        onTap: () {
          if (entry.isDirectory) {
            _toggleExpand(entry.path);
          } else {
            widget.onOpenFile(entry.path);
          }
        },
        child: Container(
          height: 22,
          color: isOpen ? CursorColors.active : Colors.transparent,
          padding: EdgeInsets.only(left: 8.0 + depth * 12.0, right: 8),
          child: Row(
            children: [
              if (entry.isDirectory)
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 14,
                  color: CursorColors.fgMuted,
                )
              else
                SizedBox(width: 14),
              Icon(
                entry.isDirectory
                    ? Icons.folder
                    : Icons.insert_drive_file_outlined,
                size: 14,
                color: entry.isDirectory
                    ? const Color(0xFFC09553)
                    : CursorColors.fgMuted,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isOpen ? Colors.white : CursorColors.fg,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      widgets.add(
        entry.isDirectory
            ? row
            : Draggable<String>(
                data: entry.path,
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: CursorColors.panel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CursorColors.border),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x44000000),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.insert_drive_file_outlined,
                          size: 14,
                          color: CursorColors.fgMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          entry.name,
                          style: TextStyle(
                            color: CursorColors.fgBright,
                            fontSize: 12,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.4, child: row),
                child: row,
              ),
      );

      if (entry.isDirectory && isExpanded) {
        widgets.addAll(_buildTree(entry.path, depth + 1));
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final root = widget.rootPath;
    final title = root == null ? 'NO FOLDER' : p.basename(root).toUpperCase();

    return ColoredBox(
      color: CursorColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 35,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: CursorColors.fg,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  _IconBtn(
                    icon: Icons.refresh,
                    tooltip: 'Refresh',
                    onTap: root == null
                        ? null
                        : () => setState(() => _refreshToken++),
                  ),
                  _IconBtn(
                    icon: Icons.folder_open,
                    tooltip: 'Open Folder',
                    onTap: kIsWeb ? null : () => widget.onPickFolder(),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: root == null
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kIsWeb
                              ? 'File explorer is desktop/mobile only.'
                              : 'You have not yet opened a folder.',
                          style: TextStyle(
                            color: CursorColors.fgMuted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                        if (!kIsWeb) ...[
                          SizedBox(height: 12),
                          TextButton(
                            onPressed: () => widget.onPickFolder(),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: CursorColors.accent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            child: Text(
                              'Open Folder',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView(
                    key: ValueKey('$_refreshToken|$root'),
                    padding: const EdgeInsets.only(bottom: 8),
                    children: _buildTree(root, 0),
                  ),
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
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

class _FsEntry {
  const _FsEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
  });

  final String path;
  final String name;
  final bool isDirectory;
}
