import 'package:flutter/material.dart';

import '../services/ollama_service.dart';
import '../theme/cursor_theme.dart';

class TransparencyPanel extends StatelessWidget {
  const TransparencyPanel({
    super.key,
    required this.status,
    required this.model,
    required this.onModelChanged,
    required this.onRefresh,
    this.fileName,
  });

  final OllamaStatus? status;
  final String model;
  final ValueChanged<String> onModelChanged;
  final VoidCallback onRefresh;
  final String? fileName;

  @override
  Widget build(BuildContext context) {
    final c = IdeColors.of(context);
    final online = status?.online == true;
    final models = status?.models ?? const <String>[];

    return Container(
      height: 22,
      color: c.accent,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(
            online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 12,
            color: Colors.white,
          ),
          const SizedBox(width: 6),
          Text(
            online ? 'on-device' : 'ollama offline',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 14),
          if (fileName != null) ...[
            const Icon(Icons.insert_drive_file_outlined, size: 11, color: Colors.white70),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                fileName!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
            const SizedBox(width: 14),
          ],
          PopupMenuButton<String>(
            tooltip: 'Model',
            onSelected: onModelChanged,
            color: c.panel,
            itemBuilder: (context) => [
              for (final name in models)
                PopupMenuItem(
                  value: name,
                  child: Text(name, style: TextStyle(fontSize: 12, color: c.fg)),
                ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  model,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                const Icon(Icons.arrow_drop_down, size: 14, color: Colors.white70),
              ],
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: onRefresh,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.refresh, size: 13, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
