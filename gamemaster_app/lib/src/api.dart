// The control server's REST API (same network, by IP address): who has a QR
// card (registered on the website, synced to the server), assigning them to a
// place, removing them.

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import 'model.dart';

class ApiError implements Exception {
  ApiError(this.message);
  final String message;
  @override
  String toString() => message;
}

class Player {
  Player(this.id, this.name, this.age, this.card);
  final int id;
  final String name;
  final int age;
  final String? card;

  factory Player.fromJson(Map<String, dynamic> j) =>
      Player((j['id'] as num).toInt(), '${j['name']}', (j['age'] as num? ?? 0).toInt(), j['card'] as String?);
}

class Gamemaster {
  Gamemaster(this.id, this.name, this.color);
  final int id;
  final String name;
  final Color color;

  factory Gamemaster.fromJson(Map<String, dynamic> j) =>
      Gamemaster((j['id'] as num).toInt(), '${j['name']}', parseHex('${j['color']}') ?? assignColors[0]);
}

/// A place (1-13 floor, 14-18 mobile) and the physical tile on it.
class Place {
  Place(this.number, this.device, this.enabled);
  final int number;
  final String? device;          // the tile's id (MAC address), null = none
  final bool enabled;
}

/// A physical tile as it announced itself (device/<id>/hello).
class Device {
  Device(this.id, this.online, this.info);
  final String id;
  final bool online;
  final Map<String, dynamic> info;   // what the tile told about itself (firmware, ...)
}

class Hardware {
  Hardware(this.places, this.devices);
  final List<Place> places;
  final List<Device> devices;

  factory Hardware.fromJson(Map<String, dynamic> j) {
    final places = [
      for (final t in (j['tiles'] as List? ?? []))
        Place(((t as Map)['number'] as num).toInt(), t['device'] as String?, t['enabled'] == 1 || t['enabled'] == true),
    ];
    final devices = [
      for (final d in (j['devices'] as List? ?? []))
        Device('${(d as Map)['device']}', d['online'] == true,
            {for (final e in d.entries) if (!const {'device', 'online', 'seen'}.contains(e.key)) '${e.key}': e.value}),
    ];
    return Hardware(places, devices);
  }

  Place? place(int n) => places.where((p) => p.number == n).firstOrNull;
  Device? device(String? id) => id == null ? null : devices.where((d) => d.id == id).firstOrNull;

  /// Tiles seen that stand on no place (new, or a spare).
  List<Device> get unplaced {
    final used = {for (final p in places) p.device};
    return devices.where((d) => !used.contains(d.id)).toList();
  }
}

class Config {
  Config(this.mqtt, this.prefix, this.floorTiles, this.places, this.t01Clock);
  final String mqtt;             // ws://host:port of the broker
  final String prefix;
  final int floorTiles;
  final int places;
  final double t01Clock;         // the venue's layout: T01 at this hour, the entrance at 6
}

class Api {
  Api(this.base, {http.Client? client}) : _http = client ?? http.Client();

  /// e.g. http://192.168.1.10:8080
  final String base;
  final http.Client _http;

  Uri _u(String path) => Uri.parse('$base$path');

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, _u(path))..headers['Content-Type'] = 'application/json';
    if (body != null) req.body = jsonEncode(body);
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 6)));
    } catch (e) {
      throw ApiError('Geen verbinding met de server ($base)');
    }
    if (r.statusCode == 404) return null;
    if (r.statusCode >= 300) throw ApiError('${r.statusCode}: ${r.body}');
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  Future<Config> config() async {
    final j = await _send('GET', '/api/config') as Map<String, dynamic>?;
    if (j == null) throw ApiError('Dit is geen Cyber Circle Challenge server ($base)');
    return Config('${j['mqtt']}', '${j['prefix']}', (j['floor_tiles'] as num).toInt(), (j['places'] as num).toInt(),
        (j['t01_clock'] as num? ?? 12).toDouble());
  }

  /// The player registered with this QR card, or null.
  Future<Player?> card(String code) async {
    final j = await _send('GET', '/api/cards/${Uri.encodeComponent(code)}');
    return j == null ? null : Player.fromJson(j as Map<String, dynamic>);
  }

  /// A visitor without a phone, registered by the gamemaster with their card
  /// (the same as the registration website does).
  Future<Player> register(String code, String name, int age, String email) async {
    final j = await _send('PUT', '/api/cards/${Uri.encodeComponent(code)}',
        {'name': name, 'age': age, if (email.isNotEmpty) 'email': email}) as Map<String, dynamic>;
    return Player((j['id'] as num).toInt(), name, age, code);
  }

  /// To a place (0 = any free floor tile), by this gamemaster: the tile lights
  /// up in their colour.
  /// The player's accessible page (blind / partially sighted players): its
  /// link and the link's QR code (an image the server makes).
  Future<({String url, String qr, bool video})> a11yLink(int playerId) async {
    final j = await _send('POST', '/api/players/$playerId/a11y') as Map<String, dynamic>;
    return (url: '${j['url']}', qr: '${j['qr']}', video: j['video'] == true);
  }

  /// tile 0: the game picks a free floor tile - mobile: else a free mobile place.
  Future<void> assign(int playerId, int tile, Gamemaster gm, {bool mobile = false}) =>
      _send('POST', '/api/players/$playerId/assign',
          {'tile': tile, 'gamemaster': gm.id, 'color': colorHex(gm.color), if (mobile) 'mobile': true});

  /// The places and the physical tiles: which tile (its MAC address, as it
  /// announces itself over MQTT) stands on which place, and the tiles seen.
  Future<Hardware> hardware() async {
    final j = await _send('GET', '/api/tiles') as Map<String, dynamic>;
    return Hardware.fromJson(j);
  }

  /// Put a physical tile on a place ('' = none); during play only on a place
  /// that is out of service (the server refuses otherwise: 409).
  Future<void> setDevice(int tile, String device) => _send('PUT', '/api/tiles/$tile', {'device': device});

  /// A place in / out of service (a player on it leaves the game).
  Future<void> setEnabled(int tile, bool on) => _send('PUT', '/api/tiles/$tile', {'enabled': on});

  /// Light up a physical tile so you find it.
  Future<void> identify(String device) => _send('POST', '/api/devices/${Uri.encodeComponent(device)}/identify');

  /// The gamemasters (managed in the control server).
  Future<List<Gamemaster>> gamemasters() async {
    final j = await _send('GET', '/api/gamemasters') as List? ?? [];
    return [for (final g in j) Gamemaster.fromJson(g as Map<String, dynamic>)];
  }

  /// Is the registration website up? 'ok' / 'down' / 'unknown' (the control
  /// server checks its health endpoint).
  Future<String> websiteStatus() async {
    final j = await _send('GET', '/api/website') as Map<String, dynamic>?;
    return '${j?['status'] ?? 'unknown'}';
  }

  /// Sign of life: this device, used by this gamemaster now (0 = logged out).
  Future<void> session(String device, int gamemaster) =>
      _send('POST', '/api/session', {'device': device, 'gamemaster': gamemaster});

  /// Cancel an invite / remove a player from their place.
  Future<void> leave(int tile) => _send('POST', '/api/tiles/$tile/leave');
}
