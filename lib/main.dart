import 'package:flutter/material.dart';

import 'screens/ide_shell.dart';
import 'theme/cursor_theme.dart';
import 'theme/theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TryHardIdeApp());
}

class TryHardIdeApp extends StatefulWidget {
  const TryHardIdeApp({super.key});

  @override
  State<TryHardIdeApp> createState() => _TryHardIdeAppState();
}

class _TryHardIdeAppState extends State<TryHardIdeApp> {
  ThemeMode _mode = ThemeMode.dark;

  void _toggle() {
    setState(() {
      _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  void _setMode(ThemeMode mode) {
    setState(() => _mode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return ThemeController(
      mode: _mode,
      toggle: _toggle,
      setMode: _setMode,
      child: MaterialApp(
        title: 'TryHard IDE',
        debugShowCheckedModeBanner: false,
        theme: buildIdeTheme(Brightness.light),
        darkTheme: buildIdeTheme(Brightness.dark),
        themeMode: _mode,
        builder: (context, child) {
          CursorColors.bindFrom(context);
          return child ?? const SizedBox.shrink();
        },
        home: const IdeShell(),
      ),
    );
  }
}
