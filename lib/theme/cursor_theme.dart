import 'package:flutter/material.dart';

@immutable
class IdeColors extends ThemeExtension<IdeColors> {
  const IdeColors({
    required this.bg,
    required this.titleBar,
    required this.activityBar,
    required this.sidebar,
    required this.editor,
    required this.panel,
    required this.input,
    required this.hover,
    required this.active,
    required this.selection,
    required this.border,
    required this.fg,
    required this.fgMuted,
    required this.fgDim,
    required this.fgBright,
    required this.accent,
    required this.accentSoft,
    required this.chatUser,
    required this.chatAssistant,
    required this.statusOnline,
    required this.statusOffline,
    required this.tabActive,
    required this.tabInactive,
    required this.matchHighlight,
    required this.isDark,
  });

  final Color bg;
  final Color titleBar;
  final Color activityBar;
  final Color sidebar;
  final Color editor;
  final Color panel;
  final Color input;
  final Color hover;
  final Color active;
  final Color selection;
  final Color border;
  final Color fg;
  final Color fgMuted;
  final Color fgDim;
  final Color fgBright;
  final Color accent;
  final Color accentSoft;
  final Color chatUser;
  final Color chatAssistant;
  final Color statusOnline;
  final Color statusOffline;
  final Color tabActive;
  final Color tabInactive;
  final Color matchHighlight;
  final bool isDark;

  static IdeColors of(BuildContext context) {
    return Theme.of(context).extension<IdeColors>() ??
        (Theme.of(context).brightness == Brightness.dark ? dark : light);
  }

  static const dark = IdeColors(
    bg: Color(0xFF1E1E1E),
    titleBar: Color(0xFF181818),
    activityBar: Color(0xFF181818),
    sidebar: Color(0xFF141414),
    editor: Color(0xFF1E1E1E),
    panel: Color(0xFF181818),
    input: Color(0xFF2B2B2B),
    hover: Color(0xFF2A2A2A),
    active: Color(0xFF37373D),
    selection: Color(0xFF264F78),
    border: Color(0xFF2B2B2B),
    fg: Color(0xFFCCCCCC),
    fgMuted: Color(0xFF858585),
    fgDim: Color(0xFF6A6A6A),
    fgBright: Color(0xFFFFFFFF),
    accent: Color(0xFF0078D4),
    accentSoft: Color(0xFF3B82F6),
    chatUser: Color(0xFF2F2F2F),
    chatAssistant: Color(0xFF1E1E1E),
    statusOnline: Color(0xFF4EC9B0),
    statusOffline: Color(0xFFF14C4C),
    tabActive: Color(0xFF1E1E1E),
    tabInactive: Color(0xFF181818),
    matchHighlight: Color(0xFF3A3D41),
    isDark: true,
  );

  static const light = IdeColors(
    bg: Color(0xFFFFFFFF),
    titleBar: Color(0xFFF3F3F3),
    activityBar: Color(0xFFF3F3F3),
    sidebar: Color(0xFFF8F8F8),
    editor: Color(0xFFFFFFFF),
    panel: Color(0xFFF3F3F3),
    input: Color(0xFFFFFFFF),
    hover: Color(0xFFE8E8E8),
    active: Color(0xFFE4E6F1),
    selection: Color(0xFFADD6FF),
    border: Color(0xFFE5E5E5),
    fg: Color(0xFF3B3B3B),
    fgMuted: Color(0xFF6F6F6F),
    fgDim: Color(0xFF8B8B8B),
    fgBright: Color(0xFF1E1E1E),
    accent: Color(0xFF005FB8),
    accentSoft: Color(0xFF0078D4),
    chatUser: Color(0xFFE8F0FE),
    chatAssistant: Color(0xFFF5F5F5),
    statusOnline: Color(0xFF0F7B6C),
    statusOffline: Color(0xFFC72E2E),
    tabActive: Color(0xFFFFFFFF),
    tabInactive: Color(0xFFF3F3F3),
    matchHighlight: Color(0xFFFFE08A),
    isDark: false,
  );

  @override
  IdeColors copyWith({bool? isDark}) => this;

  @override
  IdeColors lerp(ThemeExtension<IdeColors>? other, double t) {
    if (other is! IdeColors) return this;
    return t < 0.5 ? this : other;
  }
}

/// Static accessors for widgets — bound each frame via [bindFrom].
abstract final class CursorColors {
  static IdeColors _c = IdeColors.dark;

  static void bindFrom(BuildContext context) {
    _c = IdeColors.of(context);
  }

  static Color get bg => _c.bg;
  static Color get titleBar => _c.titleBar;
  static Color get activityBar => _c.activityBar;
  static Color get sidebar => _c.sidebar;
  static Color get editor => _c.editor;
  static Color get panel => _c.panel;
  static Color get input => _c.input;
  static Color get hover => _c.hover;
  static Color get active => _c.active;
  static Color get selection => _c.selection;
  static Color get border => _c.border;
  static Color get fg => _c.fg;
  static Color get fgMuted => _c.fgMuted;
  static Color get fgDim => _c.fgDim;
  static Color get fgBright => _c.fgBright;
  static Color get accent => _c.accent;
  static Color get accentSoft => _c.accentSoft;
  static Color get chatUser => _c.chatUser;
  static Color get chatAssistant => _c.chatAssistant;
  static Color get statusOnline => _c.statusOnline;
  static Color get statusOffline => _c.statusOffline;
  static Color get tabActive => _c.tabActive;
  static Color get tabInactive => _c.tabInactive;
  static Color get matchHighlight => _c.matchHighlight;
  static bool get isDark => _c.isDark;
}

ThemeData buildIdeTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? IdeColors.dark : IdeColors.light;
  final base = brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: colors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: colors.accent,
      brightness: brightness,
      surface: colors.bg,
    ),
    dividerColor: colors.border,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.hover,
      contentTextStyle: TextStyle(
        color: colors.fgBright,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 6,
    ),
    extensions: <ThemeExtension<dynamic>>[colors],
  );
}
