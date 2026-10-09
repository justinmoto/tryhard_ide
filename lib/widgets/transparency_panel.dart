import 'package:flutter/material.dart';

import '../services/ollama_service.dart';

class TransparencyPanel extends StatelessWidget {
  const TransparencyPanel({
    super.key,
    required this.status,
    required this.model,
    required this.onModelChanged,
    required this.onRefresh,
  });

  final OllamaStatus? status;
  final String model;
  final ValueChanged<String> onModelChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final online = status?.online == true;
    final models = status?.models ?? const <String>[];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF12141A),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: online
                  ? const Color(0xFF163528)
                  : const Color(0xFF3A1F1F),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              online ? '100% on-device' : 'Ollama offline',
              style: TextStyle(
                color: online ? const Color(0xFF7DFFB3) : const Color(0xFFFF8E8E),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Model',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: models.contains(model) ? model : null,
              hint: Text(
                model,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              dropdownColor: const Color(0xFF1C1F27),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              items: [
                for (final name in models)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: models.isEmpty
                  ? null
                  : (value) {
                      if (value != null) onModelChanged(value);
                    },
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh Ollama',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 18, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
