// CyberControl (the Cyber Circle Challenge gamemaster app): scan a visitor's QR card, register them if the
// card is new, and assign them to a floor tile or (mobile players) a drone -
// in this gamemaster's colour. Talks to the control server by IP address
// (REST) and follows the game live (MQTT; in the browser through the server).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app_state.dart';
import 'src/event_page.dart';
import 'src/login_page.dart';
import 'src/model.dart';
import 'src/tiles_page.dart';
import 'src/scan_page.dart';
import 'src/settings_page.dart';
import 'src/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();   // (the app state watches the phone sleep / wake up)
  final app = AppState();
  app.load();
  runApp(GamemasterApp(app: app));
}

class GamemasterApp extends StatelessWidget {
  const GamemasterApp({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CyberControl',
        theme: Retro.theme(),
        debugShowCheckedModeBanner: false,
        home: HomePage(app: app),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app});
  final AppState app;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _settings = 3;
  int _tab = 0;
  Set<int> _broken = {};

  @override
  void initState() {
    super.initState();
    widget.app.live.addListener(_onLive);
  }

  @override
  void dispose() {
    widget.app.live.removeListener(_onLive);
    super.dispose();
  }

  /// A tile broke (the control server's alert, in the game's state): the phone buzzes.
  void _onLive() {
    final now = widget.app.live.state.broken;
    if (now.difference(_broken).isNotEmpty) HapticFeedback.vibrate();
    _broken = Set.of(now);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.live]),
      builder: (context, _) {
        final tab = app.configured ? _tab : _settings;        // first time: the settings
        final s = app.live.state;
        final login = app.configured && app.gamemaster == null && tab != _settings;   // who uses the app now?
        return Scaffold(
          appBar: AppBar(
            title: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                color: Retro.teal,
                child: const Text('CYBERCONTROL', style: TextStyle(color: Retro.bg, fontWeight: FontWeight.bold, fontSize: 14)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(s.summary, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis)),
            ]),
            actions: [
              if (app.gamemaster != null)
                TextButton(
                  onPressed: app.logout,
                  style: TextButton.styleFrom(backgroundColor: app.color, foregroundColor:
                      app.color.computeLuminance() > 0.45 ? Retro.bg : Colors.white,
                      shape: const BeveledRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
                  child: Text('${app.gamemaster!.name.toUpperCase()} · WISSEL',
                      style: const TextStyle(fontFamily: 'DejaVuSansMono', fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Icon(Icons.circle, size: 12, color: app.live.connected ? Retro.good : Retro.bad),
              ),
            ],
          ),
          body: Column(children: [
            if (app.configured && !app.online && !login)       // the connection dropped: it keeps trying
              Container(
                width: double.infinity,
                color: Retro.bad,
                padding: const EdgeInsets.all(6),
                child: const Text('GEEN VERBINDING - zit je op de wifi van de installatie? (probeert opnieuw)',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            for (final text in s.brokenTexts)                   // a tile broken: the gamemasters must go there
              Container(
                width: double.infinity,
                color: Retro.bad,
                padding: const EdgeInsets.all(6),
                child: Text('⚠ $text', textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            if (s.closing.banner.isNotEmpty)                    // the closing time: nobody new any more
              Container(
                width: double.infinity,
                color: Retro.amber,
                padding: const EdgeInsets.all(6),
                child: Text(s.closing.banner, textAlign: TextAlign.center,
                    style: const TextStyle(color: Retro.bg, fontWeight: FontWeight.bold)),
              ),
            if (app.online && !login && app.api != null && !s.closing.lastEntryPassed)   // busy: visitors waiting
              _BusyBar(app: app, pressure: s.pressure),
            if (app.online && app.website == 'down')            // registrations stop coming in
              Container(
                width: double.infinity,
                color: Retro.amber,
                padding: const EdgeInsets.all(6),
                child: const Text('WEBSITE OFFLINE - nieuwe registraties komen niet binnen',
                    textAlign: TextAlign.center, style: TextStyle(color: Retro.bg, fontWeight: FontWeight.bold)),
              ),
            Expanded(
              child: login
                  ? LoginPage(app: app, onSettings: () => setState(() => _tab = _settings))
                  : IndexedStack(index: tab, children: [
                      tab == 0 && app.api != null ? ScanPage(app: app) : const SizedBox(),   // (the camera only while visible)
                      TilesPage(app: app),
                      app.api != null ? EventPage(app: app, visible: tab == 2) : const SizedBox(),
                      SettingsPage(app: app),
                    ]),
            ),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Scannen'),
              NavigationDestination(icon: Icon(Icons.grid_view), label: 'Tegels'),
              NavigationDestination(icon: Icon(Icons.event), label: 'Event'),
              NavigationDestination(icon: Icon(Icons.settings), label: 'Instellingen'),
            ],
          ),
        );
      },
    );
  }
}


/// Busy or not: one tap switches it (the control server tells the game; the
/// game's state brings it back to every app). Busy and the floor full: the game
/// gets a level harder per round, so the line moves on.
class _BusyBar extends StatelessWidget {
  const _BusyBar({required this.app, required this.pressure});
  final AppState app;
  final Pressure pressure;

  @override
  Widget build(BuildContext context) {
    final p = pressure;
    final color = !p.busy ? Retro.panel : p.level >= 3 ? Retro.bad : p.level == 2 ? Retro.orange : Retro.amber;
    final fg = !p.busy ? Retro.dim : (p.level >= 3 ? Colors.white : Retro.bg);
    return Material(
      color: color,
      child: InkWell(
        onTap: () async {
          try {
            await app.api!.setBusy(!p.busy, app.gamemaster?.id ?? 0);
            HapticFeedback.selectionClick();
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Drukte niet gewijzigd: $e')));
            }
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Text(p.busy ? '🔥 ' : '', style: const TextStyle(fontSize: 16)),
            Expanded(child: Text(p.text, style: TextStyle(color: fg, fontWeight: FontWeight.bold))),
            Text(p.busy ? 'ZET UIT' : 'ER WACHTEN MENSEN? TIK',
                style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.bold)),
          ]),
        ),
      ),
    );
  }
}
