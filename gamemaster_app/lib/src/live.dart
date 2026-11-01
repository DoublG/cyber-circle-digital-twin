// The game's live state for the screens of the app: from MQTT on the phone,
// through the control server in the browser.

import 'package:flutter/foundation.dart';

import 'live_mqtt.dart' if (dart.library.html) 'live_sse.dart' as source;
import 'model.dart';

class Live extends ChangeNotifier {
  GameState state = GameState();
  bool connected = false;
  String? error;
  void Function()? _stop;

  Future<void> connect({required String server, required String mqttUrl, required String prefix,
      String user = '', String password = ''}) async {
    _stop?.call();
    connected = false;
    error = null;
    notifyListeners();
    _stop = await source.startLive(
      server: server,
      mqttUrl: mqttUrl,
      prefix: prefix,
      user: user,
      password: password,
      onState: (j) {
        state = GameState.fromJson(j);
        notifyListeners();
      },
      onStatus: (ok, err) {
        connected = ok;
        error = err;
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _stop?.call();
    super.dispose();
  }
}
