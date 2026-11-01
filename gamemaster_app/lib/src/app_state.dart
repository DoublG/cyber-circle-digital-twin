// The app's state: where the control server is (its IP address on the
// installation's wifi), who uses the phone now (a gamemaster - helpers take
// turns all day), and the connection: REST, the live state, a sign of life.
// Always ready: it reconnects by itself - when the phone wakes up, back on
// the wifi, every few seconds while there is no connection - and after a
// while in the background it asks who is using it.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'live.dart';
import 'model.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  String host = '';                // the control server's IP address on the local wifi
  int port = 8080;
  String mqttUser = '';
  String mqttPassword = '';
  String device = '';              // this phone / browser (for the sign of life)
  /// Fast: a scanned card goes straight to a free floor tile (500 visitors a
  /// session: scan, scan, scan); off: choose the place for every visitor.
  bool quickAssign = true;
  Gamemaster? gamemaster;          // who uses the app now (null: choose)
  int lastGamemaster = 0;          // (the one to suggest)
  List<Gamemaster> gamemasters = [];
  Api? api;
  Config? config;
  String? error;
  bool connecting = false;
  final live = Live();
  Timer? _beat;
  DateTime? _paused;

  /// After this long in the background: who uses the app now?
  static const askAgainAfter = Duration(minutes: 10);

  /// In the browser the app comes from the control server itself.
  String get server => kIsWeb ? Uri.base.origin : 'http://$host:$port';

  bool get configured => kIsWeb || host.isNotEmpty;

  bool get online => config != null && live.connected;

  /// The colour of the tiles this gamemaster's visitors go to.
  Color get color => gamemaster?.color ?? assignColors[0];

  /// The venue's layout (set up in the control server): T01 at this hour,
  /// the entrance at 6 - live in the browser, else from the last connect.
  double get t01Clock => live.state.t01Clock ?? config?.t01Clock ?? 12;

  Future<void> load() async {
    WidgetsBinding.instance.addObserver(this);
    final p = await SharedPreferences.getInstance();
    host = p.getString('host') ?? '';
    port = p.getInt('port') ?? 8080;
    mqttUser = p.getString('mqtt_user') ?? '';
    mqttPassword = p.getString('mqtt_password') ?? '';
    quickAssign = p.getBool('quick') ?? true;
    lastGamemaster = p.getInt('gamemaster') ?? 0;
    device = p.getString('device') ?? '';
    if (device.isEmpty) {
      device = 'gm-${Random().nextInt(1 << 32).toRadixString(16)}';
      await p.setString('device', device);
    }
    notifyListeners();
    _beat = Timer.periodic(const Duration(seconds: 5), (_) => _heartbeat());
    if (configured) await connect();
  }

  Future<void> setQuick(bool on) async {
    quickAssign = on;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('quick', on);
  }

  Future<void> login(Gamemaster gm) async {
    gamemaster = gm;
    lastGamemaster = gm.id;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt('gamemaster', gm.id);
    _heartbeat();
  }

  /// WISSEL: the next helper picks their name.
  void logout() {
    gamemaster = null;
    notifyListeners();
    api?.session(device, 0).catchError((_) {});
  }

  Future<void> save({required String host, required int port, required String user, required String password}) async {
    this.host = host.trim();
    this.port = port;
    mqttUser = user;
    mqttPassword = password;
    final p = await SharedPreferences.getInstance();
    await p.setString('host', this.host);
    await p.setInt('port', port);
    await p.setString('mqtt_user', user);
    await p.setString('mqtt_password', password);
    await connect();
  }

  /// Asks the server where MQTT is and who the gamemasters are, then follows
  /// the game live.
  Future<void> connect() async {
    if (connecting) return;
    connecting = true;
    error = null;
    notifyListeners();
    try {
      api = Api(server);
      config = await api!.config();
      gamemasters = await api!.gamemasters();
      if (gamemaster != null) {                  // (renamed / recoloured / removed meanwhile)
        final now = gamemasters.where((g) => g.id == gamemaster!.id);
        gamemaster = now.isEmpty ? null : now.first;
      }
      await live.connect(server: server, mqttUrl: config!.mqtt, prefix: config!.prefix,
          user: mqttUser, password: mqttPassword);
    } catch (e) {
      config = null;
      error = '$e';
    }
    connecting = false;
    notifyListeners();
  }

  /// Every 5 s: the sign of life, and a new attempt while there is no
  /// connection (the phone just came onto the installation's wifi).
  Future<void> _heartbeat() async {
    if (!configured) return;
    if (config == null || !live.connected) {
      await connect();
      return;
    }
    final gm = gamemaster;
    if (gm == null) return;
    try {
      await api!.session(device, gm.id);
    } catch (_) {
      config = null;                             // (the next beat reconnects)
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _paused ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _paused == null ? Duration.zero : DateTime.now().difference(_paused!);
      _paused = null;
      if (away > askAgainAfter) gamemaster = null;   // phone was away a while: who is it now?
      notifyListeners();
      connect();                                     // (after sleep: the connections are stale)
    }
  }

  @override
  void dispose() {
    _beat?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
