// Who uses the app now? Helpers take turns all day: one tap on your name (in
// your colour). Shown at the start, after WISSEL and after a while in the
// background. Without a connection: what to check (the installation's wifi);
// it keeps trying by itself.

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'theme.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key, required this.app, required this.onSettings});
  final AppState app;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    if (app.config == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off, size: 64, color: Retro.bad),
            const SizedBox(height: 12),
            const Text('Geen verbinding met de control server', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Zit je op de wifi van de installatie?\n${app.server}\n\nDe app probeert het zelf opnieuw.',
                textAlign: TextAlign.center, style: const TextStyle(color: Retro.dim)),
            if (app.error != null)
              Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text(app.error!, textAlign: TextAlign.center, style: const TextStyle(color: Retro.bad, fontSize: 12))),
            const SizedBox(height: 16),
            if (app.connecting) const CircularProgressIndicator(),
            const SizedBox(height: 16),
            TextButton(onPressed: onSettings, child: const Text('instellingen')),
          ]),
        ),
      );
    }
    final gms = app.gamemasters;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('WIE BEN JIJ?', style: TextStyle(color: Retro.teal, fontWeight: FontWeight.bold, fontSize: 22)),
      const SizedBox(height: 4),
      const Text('Kies je naam: de tegels van wie jij toewijst lichten op in jouw kleur.',
          style: TextStyle(color: Retro.dim)),
      const SizedBox(height: 14),
      if (gms.isEmpty)
        const Text('Nog geen gamemasters: voeg ze toe in de control server (Gamemasters).',
            style: TextStyle(color: Retro.amber)),
      for (final g in gms)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            height: 70,
            child: FilledButton(
              onPressed: () => app.login(g),
              style: FilledButton.styleFrom(
                backgroundColor: g.color,
                foregroundColor: g.color.computeLuminance() > 0.45 ? Retro.bg : Colors.white,
                side: g.id == app.lastGamemaster ? const BorderSide(color: Retro.cream, width: 4) : null,
              ),
              child: Text(g.name.toUpperCase(), style: const TextStyle(fontFamily: 'DejaVuSansMono', fontSize: 26,
                  fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      TextButton(onPressed: app.connect, child: const Text('vernieuw')),
    ]);
  }
}
