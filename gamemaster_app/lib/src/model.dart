// The game as the gamemaster app sees it: the live state the game publishes
// on MQTT (<prefix>/state, the same JSON the web interface gets) and the
// places: T01-T13 the floor tiles around the robot, M1-M5 the mobile
// players (a handheld tile; a drone in the game).

import 'dart:ui';

const defaultFloorTiles = 13;
const defaultPlaces = 18;

/// A place as the screens show it: "T03" / "M2".
String placeLabel(int tile, {int floorTiles = defaultFloorTiles}) =>
    tile <= floorTiles ? 'T${tile.toString().padLeft(2, '0')}' : 'M${tile - floorTiles}';

/// The place number in binary on the 5 hearts, as the tiles show it in the
/// setup (heart 1 nearest the logo = 1, heart 2 = 2, ... heart 5 = 16): T05 = ♥♡♥♡♡.
String heartPattern(int tile) => [for (var i = 0; i < 5; i++) tile >> i & 1 == 1 ? '♥' : '♡'].join();

/// The card code in a scanned QR code: the text itself, or from a link
/// (?card=CODE or the last part of the path, e.g. http://.../c/CC-0042).
String? cardCode(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final q = uri.queryParameters['card'];
    if (q != null && q.trim().isNotEmpty) return q.trim();
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.last;
  }
  return text;
}

/// The colours the gamemaster can give an assignment: the tile lights up in
/// it so the visitor finds it (players themselves have no colour).
const assignColors = <Color>[
  Color(0xFFFF8800), Color(0xFF33CCFF), Color(0xFFFF44CC), Color(0xFF88FF00), Color(0xFFFFEE00),
  Color(0xFFAA55FF), Color(0xFFFF3344), Color(0xFF00FFCC), Color(0xFFFFFFFF),
];

String colorHex(Color c) => '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

Color? parseHex(String? s) {
  if (s == null) return null;
  final h = s.replaceFirst('#', '');
  final v = int.tryParse(h, radix: 16);
  return v == null || h.length != 6 ? null : Color(0xFF000000 | v);
}

enum PlaceStatus { free, pending, playing, disabled }

class TilePlayer {
  TilePlayer(this.tile, this.name, this.lives, this.maxLives, this.out, this.playerId);
  final int tile;
  final int playerId;            // in the database (0: not from it)
  final String name;
  final int lives;
  final int maxLives;
  final bool out;
}

class Invite {
  Invite(this.tile, this.name, this.color, this.playerId);
  final int tile;
  final int playerId;
  final String name;
  final Color color;
}

class GameState {
  GameState({
    this.state = '',
    this.mode = '',
    this.round = '',
    this.uitslag = false,
    this.t01Clock,
    this.floorTiles = defaultFloorTiles,
    this.places = defaultPlaces,
    Map<int, TilePlayer>? players,
    Map<int, Invite>? pending,
    Set<int>? disabled,
    Map<int, int>? dying,
    Set<int>? installed,
  })  : installed = installed ?? {for (var t = 1; t <= places; t++) t},
        players = players ?? {},
        pending = pending ?? {},
        disabled = disabled ?? {},
        dying = dying ?? {};

  final String state;            // LOBBY / INTRO / PLAYING / SCOREBOARD ('' = no game yet)
  final String mode;             // setup / closed / open / paused
  final String round;
  final bool uitslag;
  final double? t01Clock;        // (through the control server only: the venue's layout)
  final int floorTiles;
  final int places;
  final Map<int, TilePlayer> players;
  final Map<int, Invite> pending;
  final Set<int> disabled;
  /// Exterminated players' tiles: seconds until the tile is free again
  /// (-1: the robot has not fired yet).
  final Map<int, int> dying;
  /// The places of this installation (a partial one: e.g. half the floor, or
  /// only the mobile places); the others are not shown and never used.
  final Set<int> installed;

  factory GameState.fromJson(Map<String, dynamic> j) {
    int i(dynamic v) => v is num ? v.toInt() : 0;
    final players = <int, TilePlayer>{};
    for (final p in (j['players'] as List? ?? [])) {
      final m = p as Map<String, dynamic>;
      players[i(m['tile'])] = TilePlayer(i(m['tile']), '${m['name'] ?? ''}', i(m['lives']), i(m['max_lives']),
          m['out'] == true, i(m['player_id']));
    }
    final pending = <int, Invite>{};
    for (final p in (j['pending'] as List? ?? [])) {
      final m = p as Map<String, dynamic>;
      pending[i(m['tile'])] = Invite(i(m['tile']), '${m['name'] ?? ''}', parseHex('${m['color']}') ?? assignColors[0],
          i(m['player_id']));
    }
    return GameState(
      state: '${j['state'] ?? ''}',
      mode: '${j['mode'] ?? ''}',
      round: '${j['round'] ?? ''}',
      uitslag: j['uitslag'] == true,
      t01Clock: (j['t01_clock'] as num?)?.toDouble(),
      floorTiles: i(j['floor_tiles']) > 0 ? i(j['floor_tiles']) : defaultFloorTiles,
      places: i(j['tile_count']) > 0 ? i(j['tile_count']) : defaultPlaces,
      players: players,
      pending: pending,
      disabled: {for (final d in (j['disabled'] as List? ?? [])) i(d)},
      installed: j['installed'] is List ? {for (final d in j['installed'] as List) i(d)} : null,
      dying: {
        for (final d in (j['dying'] as List? ?? []))
          i((d as Map<String, dynamic>)['tile']): (d['free_in'] as num?)?.toInt() ?? -1
      },
    );
  }

  PlaceStatus status(int tile) {
    if (disabled.contains(tile) || !installed.contains(tile)) return PlaceStatus.disabled;
    if (players.containsKey(tile)) return PlaceStatus.playing;
    if (pending.containsKey(tile)) return PlaceStatus.pending;
    return PlaceStatus.free;
  }

  bool isMobile(int tile) => tile > floorTiles;

  /// The tile is in an extermination (comes free soon).
  bool isDying(int tile) => dying.containsKey(tile);

  /// "☠ 12s" / "☠ …" (the robot still has to fire).
  String dyingText(int tile) {
    final s = dying[tile];
    return s == null ? '' : (s < 0 ? '☠ …' : '☠ ${s}s');
  }

  /// Free places now: floor tiles, and mobile places (drones).
  /// The installed floor tiles / mobile places (in order).
  List<int> get floorPlaces => [for (var t = 1; t <= floorTiles; t++) if (installed.contains(t)) t];
  List<int> get mobilePlaces => [for (var t = floorTiles + 1; t <= places; t++) if (installed.contains(t)) t];
  bool isInstalled(int tile) => installed.contains(tile);

  int get freeFloor => floorPlaces.where((t) => status(t) == PlaceStatus.free).length;
  int get freeMobile => mobilePlaces.where((t) => status(t) == PlaceStatus.free).length;
  int get enabledFloor => floorPlaces.where((t) => !disabled.contains(t)).length;
  int get enabledMobile => mobilePlaces.where((t) => !disabled.contains(t)).length;

  /// Where a player is now: (tile, playing) - invited or playing - or null.
  (int, bool)? whereIs(int playerId) {
    for (final p in pending.values) {
      if (p.playerId == playerId) return (p.tile, false);
    }
    for (final p in players.values) {
      if (p.playerId == playerId) return (p.tile, true);
    }
    return null;
  }

  String label(int tile) => placeLabel(tile, floorTiles: floorTiles);

  /// Players can join (the game is open or paused).
  bool get open => mode == 'open' || mode == 'paused';

  /// Colours of the invites waiting right now (two the same are hard to tell apart).
  Set<int> get usedColors => {for (final p in pending.values) p.color.value};

  /// One line for the top bar.
  String get summary {
    if (state.isEmpty) return 'GEEN SPEL';
    final st = const {'LOBBY': 'WACHT OP SPELERS', 'INTRO': 'INTRO', 'PLAYING': 'BEZIG', 'SCOREBOARD': 'SCOREBORD'}[state] ?? state;
    final s = state == 'SCOREBOARD' && uitslag ? 'UITSLAG' : st;
    return round.isNotEmpty && state != 'LOBBY' ? '$s: ${round.toUpperCase()}' : s;
  }
}
