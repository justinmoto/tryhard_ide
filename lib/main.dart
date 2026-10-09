import 'package:flutter/material.dart';

import 'screens/ide_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TryHardIdeApp());
}

class TryHardIdeApp extends StatelessWidget {
  const TryHardIdeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TryHard IDE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4C7FFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
      ),
      home: const IdeShell(),
    );
  }
}
