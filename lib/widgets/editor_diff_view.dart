import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/line_diff.dart';
import '../theme/cursor_theme.dart';

class EditorDiffView extends StatelessWidget {
  const EditorDiffView({
    super.key,
    required this.path,
    required this.oldContent,
    required this.newContent,
    required this.onKeep,
    required this.onDiscard,
  });

  final String path;
  final String oldContent;
  final String newContent;
  final VoidCallback onKeep;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final lines = diffLines(oldContent, newContent, maxLines: 2000);
    final added = lines.where((l) => l.op == DiffOp.add).length;
    final removed = lines.where((l) => l.op == DiffOp.remove).length;
    var lineNo = 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          color: CursorColors.panel,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.compare_arrows, size: 16, color: CursorColors.accentSoft),
              const SizedBox(width: 8),
              Text(
                'DIFF',
                style: TextStyle(
                  color: CursorColors.fgBright,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  p.basename(path),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: CursorColors.fg, fontSize: 12),
                ),
              ),
              Text(
                '+$added',
                style: const TextStyle(
                  color: Color(0xFF7DFFB3),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '-$removed',
                style: const TextStyle(
                  color: Color(0xFFFF8E8E),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onDiscard,
                child: const Text(
                  'Discard',
                  style: TextStyle(
                    color: Color(0xFFFF8E8E),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: onKeep,
                child: const Text(
                  'Keep',
                  style: TextStyle(
                    color: Color(0xFF7DFFB3),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: CursorColors.border),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              late Color bg;
              late Color fg;
              late String prefix;
              String gutter = '';
              switch (line.op) {
                case DiffOp.add:
                  bg = const Color(0xFF163528);
                  fg = const Color(0xFFB6F5D0);
                  prefix = '+';
                  lineNo++;
                  gutter = '$lineNo';
                case DiffOp.remove:
                  bg = const Color(0xFF3A1A1A);
                  fg = const Color(0xFFFFC0C0);
                  prefix = '-';
                  gutter = '';
                case DiffOp.equal:
                  bg = CursorColors.editor;
                  fg = CursorColors.fgBright;
                  prefix = ' ';
                  if (line.text != '…') {
                    lineNo++;
                    gutter = '$lineNo';
                  }
              }

              return ColoredBox(
                color: bg,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 48,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8, top: 1),
                        child: Text(
                          gutter,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 12,
                            color: CursorColors.fgDim,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 18,
                      child: Text(
                        prefix,
                        style: TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 13,
                          color: fg,
                          fontWeight: FontWeight.w700,
                          height: 1.45,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        line.text,
                        style: TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 13,
                          color: fg,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
