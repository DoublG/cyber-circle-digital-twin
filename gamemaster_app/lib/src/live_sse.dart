// Live state in the browser (the web version, e.g. on an iPhone): through the
// control server's live stream (server-sent events) - a page can't use the
// MQTT broker directly (and from an https page not an unencrypted one).

import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// Starts following the game; returns a function that stops it.
Future<void Function()> startLive({
  required String server,
  required String mqttUrl,
  required String prefix,
  String user = '',
  String password = '',
  required void Function(Map<String, dynamic> state) onState,
  required void Function(bool connected, String? error) onStatus,
}) async {
  final es = html.EventSource('$server/api/live');
  es.onOpen.listen((_) => onStatus(true, null));
  es.onError.listen((_) => onStatus(false, 'Geen verbinding met de server'));
  es.onMessage.listen((e) {
    try {
      final j = jsonDecode('${e.data}') as Map<String, dynamic>;
      final mode = j['mode'];
      final state = Map<String, dynamic>.from(j['state'] as Map? ?? {});
      if (mode != null) state['mode'] = mode;          // (the server's mode is the truth)
      if (j['t01_clock'] != null) state['t01_clock'] = j['t01_clock'];   // (the venue's layout)
      onState(state);
    } catch (_) {}
  });
  return () => es.close();
}
