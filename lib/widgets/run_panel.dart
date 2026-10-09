import 'package:flutter/material.dart';

import '../services/run_service.dart';
import '../theme/cursor_theme.dart';

class RunPanel extends StatefulWidget {
  const RunPanel({
    super.key,
    required this.runService,
    required this.rootPath,
    required this.onClose,
  });

  final RunService runService;
  final String? rootPath;
  final VoidCallback onClose;

  @override
  State<RunPanel> createState() => _RunPanelState();
}

class _RunPanelState extends State<RunPanel> {
  final _scroll = ScrollController();
  List<RunTarget> _targets = const [];
  RunTarget? _selected;
  bool _loadingTargets = false;

  @override
  void initState() {
    super.initState();
    widget.runService.addListener(_onRunChanged);
    _loadTargets();
  }

  @override
  void didUpdateWidget(covariant RunPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath) {
      _loadTargets();
    }
    if (oldWidget.runService != widget.runService) {
      oldWidget.runService.removeListener(_onRunChanged);
      widget.runService.addListener(_onRunChanged);
    }
  }

  @override
  void dispose() {
    widget.runService.removeListener(_onRunChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onRunChanged() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _loadTargets() async {
    setState(() => _loadingTargets = true);
    final targets = await RunService.detectTargets(widget.rootPath);
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _selected = targets.isEmpty
          ? null
          : targets.firstWhere(
              (t) => t.id == _selected?.id,
              orElse: () => targets.first,
            );
      _loadingTargets = false;
    });
  }

  Future<void> _run() async {
    final root = widget.rootPath;
    final target = _selected;
    if (root == null) return;
    if (target == null) return;
    await widget.runService.start(workingDirectory: root, target: target);
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.runService.isRunning;
    final root = widget.rootPath;

    return ColoredBox(
      color: CursorColors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 14, color: CursorColors.fgMuted),
                  const SizedBox(width: 8),
                  Text(
                    'RUN',
                    style: TextStyle(
                      color: CursorColors.fg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_loadingTargets)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: CursorColors.fgMuted,
                      ),
                    )
                  else
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selected?.id,
                        isDense: true,
                        dropdownColor: CursorColors.panel,
                        style: TextStyle(
                          color: CursorColors.fg,
                          fontSize: 12,
                        ),
                        hint: Text(
                          root == null ? 'Open a folder first' : 'Select script',
                          style: TextStyle(
                            color: CursorColors.fgDim,
                            fontSize: 12,
                          ),
                        ),
                        items: [
                          for (final t in _targets)
                            DropdownMenuItem(
                              value: t.id,
                              child: Text(t.label),
                            ),
                        ],
                        onChanged: running
                            ? null
                            : (id) {
                                if (id == null) return;
                                setState(() {
                                  _selected = _targets.firstWhere((t) => t.id == id);
                                });
                              },
                      ),
                    ),
                  const Spacer(),
                  _ActionChip(
                    icon: Icons.play_arrow,
                    label: 'Run',
                    enabled: !running && root != null && _selected != null,
                    color: const Color(0xFF3D9A5F),
                    onTap: _run,
                  ),
                  const SizedBox(width: 6),
                  _ActionChip(
                    icon: Icons.stop,
                    label: 'Stop',
                    enabled: running,
                    color: const Color(0xFFB35A5A),
                    onTap: () => widget.runService.stop(),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Clear',
                    onPressed: widget.runService.clear,
                    icon: Icon(Icons.delete_outline, size: 16, color: CursorColors.fgMuted),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                  ),
                  IconButton(
                    tooltip: 'Refresh scripts',
                    onPressed: running ? null : _loadTargets,
                    icon: Icon(Icons.refresh, size: 16, color: CursorColors.fgMuted),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                  ),
                  IconButton(
                    tooltip: 'Close panel',
                    onPressed: widget.onClose,
                    icon: Icon(Icons.close, size: 16, color: CursorColors.fgMuted),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: CursorColors.border),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              itemCount: widget.runService.lines.length,
              itemBuilder: (context, index) {
                final line = widget.runService.lines[index];
                final isMeta = line.startsWith('[') || line.startsWith('\$') || line.startsWith('cwd:');
                return SelectableText(
                  line,
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 12,
                    height: 1.35,
                    color: isMeta ? CursorColors.fgMuted : CursorColors.fgBright,
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

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(4),
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: CursorColors.fgBright,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
