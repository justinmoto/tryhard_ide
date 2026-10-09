import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/apply_edit_result.dart';
import '../services/line_diff.dart';
import '../theme/cursor_theme.dart';

class DiffResultCard extends StatelessWidget {
  const DiffResultCard({
    super.key,
    required this.result,
    this.onOpen,
  });

  final ApplyEditResult result;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    if (!result.ok) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF3A1F1F),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFFF8E8E).withValues(alpha: 0.4)),
        ),
        child: Text(
          result.error ?? 'Apply failed',
          style: const TextStyle(color: Color(0xFFFF8E8E), fontSize: 12),
        ),
      );
    }

    final path = result.path ?? '(unknown file)';
    final name = p.basename(path);
    final lines = diffLines(
      result.oldContent ?? '',
      result.newContent ?? '',
    );
    final added = lines.where((l) => l.op == DiffOp.add).length;
    final removed = lines.where((l) => l.op == DiffOp.remove).length;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: CursorColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CursorColors.accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 14, color: Color(0xFF7DFFB3)),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Changed file',
                        style: TextStyle(
                          color: CursorColors.fgDim,
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        name,
                        style: TextStyle(
                          color: CursorColors.fgBright,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        path,
                        style: TextStyle(
                          color: CursorColors.fgMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '+$added',
                  style: const TextStyle(
                    color: Color(0xFF7DFFB3),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '-$removed',
                  style: const TextStyle(
                    color: Color(0xFFFF8E8E),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (onOpen != null) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Open file',
                    onPressed: () => onOpen!(path),
                    icon: Icon(Icons.open_in_new, size: 14, color: CursorColors.fgMuted),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: CursorColors.border),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              shrinkWrap: true,
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = lines[index];
                late Color bg;
                late Color fg;
                late String prefix;
                switch (line.op) {
                  case DiffOp.add:
                    bg = const Color(0xFF1B3D2F);
                    fg = const Color(0xFF7DFFB3);
                    prefix = '+';
                  case DiffOp.remove:
                    bg = const Color(0xFF3D1B1B);
                    fg = const Color(0xFFFF8E8E);
                    prefix = '-';
                  case DiffOp.equal:
                    bg = Colors.transparent;
                    fg = CursorColors.fgMuted;
                    prefix = ' ';
                }
                return ColoredBox(
                  color: bg,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    child: Text(
                      '$prefix ${line.text}',
                      style: TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        color: fg,
                        height: 1.3,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
