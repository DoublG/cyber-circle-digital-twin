// Live state on the phone app (Android): straight from the MQTT broker
// (websockets), the retained <prefix>/state the game publishes.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

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
  final uri = Uri.parse(mqttUrl);
  final client = MqttServerClient.withPort('${uri.scheme}://${uri.host}${uri.path}',
      'cc-gamemaster-${Random().nextInt(1 << 30)}', uri.hasPort ? uri.port : 9001);
  client.useWebSocket = uri.scheme == 'ws' || uri.scheme == 'wss';
  client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
  client.keepAlivePeriod = 20;
  client.autoReconnect = true;
  client.logging(on: false);
  client.onConnected = () => onStatus(true, null);
  client.onAutoReconnected = () => onStatus(true, null);
  client.onDisconnected = () => onStatus(false, 'MQTT verbinding weg');
  StreamSubscription? sub;
  try {
    await client.connect(user.isEmpty ? null : user, password.isEmpty ? null : password);
  } catch (e) {
    onStatus(false, 'MQTT: geen verbinding met $mqttUrl');
    client.disconnect();
    return () {};
  }
  client.subscribe('$prefix/state', MqttQos.atMostOnce);
  sub = client.updates?.listen((msgs) {
    for (final m in msgs) {
      if (m.topic != '$prefix/state') continue;
      final payload = m.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(payload.payload.message);
      try {
        onState(jsonDecode(utf8.decode(text.codeUnits)) as Map<String, dynamic>);
      } catch (_) {}
    }
  });
  onStatus(true, null);
  return () {
    sub?.cancel();
    client.autoReconnect = false;
    client.disconnect();
  };
}
