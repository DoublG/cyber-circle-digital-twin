// The control server (its IP address on the local wifi), the MQTT login and
// this gamemaster's colour.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'floor_plan.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});
  final AppState app;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _host = TextEditingController(text: widget.app.host);
  late final _port = TextEditingController(text: '${widget.app.port}');
  late final _user = TextEditingController(text: widget.app.mqttUser);
  late final _pass = TextEditingController(text: widget.app.mqttPassword);

  AppState get app => widget.app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.live]),
      builder: (context, _) {
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (app.gamemaster != null) ...[
            Row(children: [
              Container(width: 22, height: 22, color: app.color),
              const SizedBox(width: 10),
              Expanded(child: Text('Ingelogd als ${app.gamemaster!.name}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
              OutlinedButton(onPressed: app.logout, child: const Text('WISSEL')),
            ]),
            const Text('Naam en kleur van de gamemasters: in de control server (Gamemasters).',
                style: TextStyle(color: Retro.dim)),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: app.quickAssign,
            onChanged: app.setQuick,
            title: const Text('Snel toewijzen'),
            subtitle: const Text('Een gescande kaart gaat meteen naar een vrije vloertegel (het spel vult de lege '
                'plaatsen). Uit: voor elke bezoeker de plaats kiezen.', style: TextStyle(color: Retro.dim)),
          ),
          const SizedBox(height: 16),
          const Text('OPSTELLING', style: TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
          Text('De ingang onderaan (6 uur), T01 op ${app.t01Clock.toStringAsFixed(app.t01Clock % 1 == 0 ? 0 : 1)} uur - '
              'ingesteld in de control server (Tegels › Opstelling).', style: const TextStyle(color: Retro.dim)),
          const SizedBox(height: 6),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260),
              child: FloorPlan(state: app.live.state, t01Clock: app.t01Clock)),
          const SizedBox(height: 16),
          const Text('VERBINDING', style: TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
          if (kIsWeb)
            Text('Server: ${app.server}', style: const TextStyle(color: Retro.dim))
          else ...[
            const Text('Het IP-adres van de control server op de wifi van de installatie.',
                style: TextStyle(color: Retro.dim)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(flex: 3, child: TextField(controller: _host, keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'IP-adres', hintText: '192.168.1.10'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _port, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Poort'))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _user, decoration: const InputDecoration(labelText: 'MQTT gebruiker'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _pass, obscureText: true,
                  decoration: const InputDecoration(labelText: 'MQTT wachtwoord'))),
            ]),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: app.connecting
                ? null
                : () => kIsWeb
                    ? app.connect()
                    : app.save(host: _host.text, port: int.tryParse(_port.text) ?? 8080, user: _user.text, password: _pass.text),
            child: Text(app.connecting ? 'VERBINDEN…' : 'OPSLAAN EN VERBINDEN'),
          ),
          const SizedBox(height: 12),
          _status('Server', app.config != null, app.error ?? (app.config == null ? 'niet verbonden' : app.server)),
          _status(kIsWeb ? 'Live (via de server)' : 'Live (MQTT)', app.live.connected,
              app.live.error ?? (app.config != null && !kIsWeb ? app.config!.mqtt : '')),
        ]);
      },
    );
  }

  Widget _status(String what, bool ok, String detail) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Icon(Icons.circle, size: 12, color: ok ? Retro.good : Retro.bad),
          const SizedBox(width: 8),
          Text('$what  ', style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(detail, style: const TextStyle(color: Retro.dim), overflow: TextOverflow.ellipsis)),
        ]),
      );
}
