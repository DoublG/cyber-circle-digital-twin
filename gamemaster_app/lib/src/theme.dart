// The look of the installation's screens and web interface: dark, orange
// frames, amber and teal text.

import 'package:flutter/material.dart';

class Retro {
  static const bg = Color(0xFF0A0807);
  static const panel = Color(0xFF17130F);
  static const orange = Color(0xFFFF7314);
  static const amber = Color(0xFFFFBD38);
  static const teal = Color(0xFF33CCBF);
  static const cream = Color(0xFFFFEECC);
  static const dim = Color(0xFF8C7A66);
  static const good = Color(0xFF4DFF73);
  static const bad = Color(0xFFFF4033);
  static const line = Color(0xFF3A2A1C);

  static ThemeData theme() {
    const scheme = ColorScheme.dark(primary: amber, secondary: teal, surface: panel, error: bad,
        onPrimary: bg, onSurface: cream);
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      fontFamily: 'DejaVuSansMono',          // (bundled: no internet on the installation's network)
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: cream,
          shape: Border(bottom: BorderSide(color: orange, width: 3))),
      navigationBarTheme: const NavigationBarThemeData(backgroundColor: panel, indicatorColor: amber),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: amber,
          foregroundColor: bg, shape: const BeveledRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6))),
          textStyle: const TextStyle(fontFamily: 'DejaVuSansMono', fontWeight: FontWeight.bold, fontSize: 16))),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: cream,
          side: const BorderSide(color: orange, width: 2),
          shape: const BeveledRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6))))),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), filled: true, fillColor: bg),
      useMaterial3: true,
    );
  }
}
