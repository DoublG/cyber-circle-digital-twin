// Cyber Circle gamemaster: scan a visitor's QR card, register them if the
// card is new, and assign them to a floor tile or (mobile players) a drone -
// in this gamemaster's colour. Talks to the control server by IP address
// (REST) and follows the game live (MQTT; in the browser through the server).

import 'package:flutter/material.dart';

import 'src/app_state.dart';
import 'src/login_page.dart';
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
        title: 'Cyber Circle Gamemaster',
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
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.live]),
      builder: (context, _) {
        final tab = app.configured ? _tab : 2;        // first time: the settings
        final s = app.live.state;
        final login = app.configured && app.gamemaster == null && tab != 2;   // who uses the app now?
        return Scaffold(
          appBar: AppBar(
            title: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                color: Retro.teal,
                child: const Text('CYBER CIRCLE', style: TextStyle(color: Retro.bg, fontWeight: FontWeight.bold, fontSize: 14)),
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
            Expanded(
              child: login
                  ? LoginPage(app: app, onSettings: () => setState(() => _tab = 2))
                  : IndexedStack(index: tab, children: [
                      tab == 0 && app.api != null ? ScanPage(app: app) : const SizedBox(),   // (the camera only while visible)
                      TilesPage(app: app),
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
              NavigationDestination(icon: Icon(Icons.settings), label: 'Instellingen'),
            ],
          ),
        );
      },
    );
  }
}
