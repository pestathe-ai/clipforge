import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() => runApp(const ClipForgeApp());

class ClipForgeApp extends StatelessWidget {
  const ClipForgeApp({super.key});

  static const accent = Color(0xFF2EE6D6);

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(primary: accent, surface: const Color(0xFF15161A));

    return MaterialApp(
      title: 'ClipForge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0D0E11),
        useMaterial3: true,
        sliderTheme: const SliderThemeData(showValueIndicator: ShowValueIndicator.always),
      ),
      home: const HomeScreen(),
    );
  }
}
