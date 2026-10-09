import 'package:flutter/material.dart';

class ThemeController extends InheritedWidget {
  const ThemeController({
    super.key,
    required this.mode,
    required this.toggle,
    required this.setMode,
    required super.child,
  });

  final ThemeMode mode;
  final VoidCallback toggle;
  final ValueChanged<ThemeMode> setMode;

  bool get isDark => mode == ThemeMode.dark;

  static ThemeController of(BuildContext context) {
    final result = context.dependOnInheritedWidgetOfExactType<ThemeController>();
    assert(result != null, 'No ThemeController found in context');
    return result!;
  }

  @override
  bool updateShouldNotify(ThemeController oldWidget) => mode != oldWidget.mode;
}
