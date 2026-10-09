import 'package:flutter/material.dart';

import '../theme/cursor_theme.dart';
import '../theme/theme_controller.dart';

enum ActivityItem { explorer, search }

class ActivityBar extends StatelessWidget {
  const ActivityBar({
    super.key,
    required this.active,
    required this.explorerOpen,
    required this.chatOpen,
    required this.onSelect,
    required this.onToggleChat,
  });

  final ActivityItem active;
  final bool explorerOpen;
  final bool chatOpen;
  final ValueChanged<ActivityItem> onSelect;
  final VoidCallback onToggleChat;

  @override
  Widget build(BuildContext context) {
    final c = IdeColors.of(context);
    final theme = ThemeController.of(context);

    return Container(
      width: 48,
      color: c.activityBar,
      child: Column(
        children: [
          const SizedBox(height: 4),
          _Item(
            icon: Icons.folder_outlined,
            tooltip: 'Explorer',
            selected: explorerOpen && active == ActivityItem.explorer,
            onTap: () => onSelect(ActivityItem.explorer),
            colors: c,
          ),
          _Item(
            icon: Icons.search,
            tooltip: 'Search',
            selected: explorerOpen && active == ActivityItem.search,
            onTap: () => onSelect(ActivityItem.search),
            colors: c,
          ),
          const Spacer(),
          _Item(
            icon: Icons.chat_bubble_outline,
            tooltip: chatOpen ? 'Hide chat' : 'Show chat',
            selected: chatOpen,
            onTap: onToggleChat,
            colors: c,
          ),
          _Item(
            icon: theme.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            tooltip: theme.isDark ? 'Switch to Light Theme' : 'Switch to Dark Theme',
            selected: false,
            onTap: theme.toggle,
            colors: c,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final IdeColors colors;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            children: [
              if (selected)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 2,
                    height: 22,
                    color: colors.fgBright,
                  ),
                ),
              Center(
                child: Icon(
                  icon,
                  size: 22,
                  color: selected ? colors.fgBright : colors.fgMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
