// Tegels: the places and the physical tiles. Every place (T01-T13 around the
// robot, M1-M5 the mobile players' handheld tiles) with the tile that stands
// on it - its MAC address, as it announces itself over MQTT - online or not,
// and who plays there. Below: tiles that announced themselves but have no
// place yet (new, or a spare to swap a broken one). Tap a place for its
// details: kick the player, out of service, swap the tile, light it up.

import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'app_state.dart';
import 'floor_plan.dart';
import 'model.dart';
import 'theme.dart';
import 'tile_detail_page.dart';

class TilesPage extends StatefulWidget {
  const TilesPage({super.key, required this.app});
  final AppState app;
  @override
  State<TilesPage> createState() => _TilesPageState();
}

class _TilesPageState extends State<TilesPage> {
  Hardware? _hw;
  Timer? _poll;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());   // (tiles come and go)
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final hw = await app.api?.hardware();
      if (mounted && hw != null) setState(() => _hw = hw);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.live,
      builder: (context, _) {
        final s = app.live.state;
        final hw = _hw;
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
                child: FloorPlan(state: s, t01Clock: app.t01Clock))),
            const SizedBox(height: 8),
            if (hw == null) const Center(child: CircularProgressIndicator()),
            if (hw != null) ...[
              _head('VLOERTEGELS'),
              for (var t = 1; t <= s.floorTiles; t++) _row(context, s, hw, t),
              _head('MOBIEL (HANDTEGELS - DRONES)'),
              for (var t = s.floorTiles + 1; t <= s.places; t++) _row(context, s, hw, t),
              _head('TEGELS ZONDER PLAATS (${hw.unplaced.length})'),
              if (hw.unplaced.isEmpty)
                const Padding(padding: EdgeInsets.all(8),
                    child: Text('Geen: elke tegel die zich meldde staat op een plaats.', style: TextStyle(color: Retro.dim))),
              for (final d in hw.unplaced) _loose(context, s, hw, d),
            ],
          ]),
        );
      },
    );
  }

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text(t, style: const TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
      );

  Widget _row(BuildContext context, GameState s, Hardware hw, int t) {
    final place = hw.place(t);
    final dev = hw.device(place?.device);
    final player = s.players[t];
    final invite = s.pending[t];
    final enabled = place?.enabled ?? true;
    final who = !enabled
        ? ('BUITEN GEBRUIK', Retro.bad)
        : player != null
            ? ('${player.name}  ${'♥' * player.lives}', Retro.cream)
            : invite != null
                ? ('${invite.name} (wacht)', invite.color)
                : ('vrij', Retro.dim);
    return Card(
      color: Retro.panel,
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(side: BorderSide(color: enabled ? Retro.line : Retro.bad, width: 1.5)),
      child: ListTile(
        dense: true,
        onTap: () => _open(context, t),
        leading: Container(
          width: 52,
          padding: const EdgeInsets.symmetric(vertical: 4),
          color: s.isMobile(t) ? Retro.amber : Retro.teal,
          child: Text(s.label(t), textAlign: TextAlign.center,
              style: const TextStyle(color: Retro.bg, fontWeight: FontWeight.bold, fontSize: 16)),
        ),
        title: Text(who.$1, style: TextStyle(color: who.$2, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
        subtitle: Row(children: [
          Icon(Icons.circle, size: 10, color: place?.device == null ? Retro.dim : (dev?.online == true ? Retro.good : Retro.bad)),
          const SizedBox(width: 6),
          Expanded(child: Text(place?.device ?? 'geen tegel gekoppeld',
              style: const TextStyle(color: Retro.dim, fontSize: 12), overflow: TextOverflow.ellipsis)),
        ]),
        trailing: const Icon(Icons.chevron_right, color: Retro.dim),
      ),
    );
  }

  /// A tile without a place: light it up, or put it on a place.
  Widget _loose(BuildContext context, GameState s, Hardware hw, Device d) => Card(
        color: Retro.panel,
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          leading: Icon(Icons.circle, size: 14, color: d.online ? Retro.good : Retro.bad),
          title: Text(d.id, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(d.online ? 'online${_info(d)}' : 'offline${_info(d)}', style: const TextStyle(color: Retro.dim, fontSize: 12)),
          trailing: Wrap(spacing: 4, children: [
            IconButton(icon: const Icon(Icons.lightbulb_outline), tooltip: 'laat oplichten',
                onPressed: () => app.api?.identify(d.id)),
            FilledButton(onPressed: () => _place(context, s, hw, d), child: const Text('PLAATS')),
          ]),
        ),
      );

  static String _info(Device d) => d.info['fw'] != null ? ' · fw ${d.info['fw']}' : '';

  Future<void> _open(BuildContext context, int t) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TileDetailPage(app: app, tile: t)));
    _load();
  }

  /// Which place does this tile go on? (Places with a tile: it swaps.)
  Future<void> _place(BuildContext context, GameState s, Hardware hw, Device d) async {
    final t = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Retro.panel,
      builder: (context) => ListView(padding: const EdgeInsets.all(12), children: [
        Text('${d.id} OP PLAATS…', style: const TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in hw.places)
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(p.number),
              style: OutlinedButton.styleFrom(side: BorderSide(color: p.device == null ? Retro.good : Retro.orange, width: 2)),
              child: Text('${s.label(p.number)}${p.device == null ? '' : ' (wissel)'}'),
            ),
        ]),
      ]),
    );
    if (t == null || !context.mounted) return;
    await placeDevice(context, app, s, hw, t, d.id);
    _load();
  }
}

/// Put a physical tile on a place, with the server's rule explained: while
/// the setup is locked a tile in service can't be swapped - first out of
/// service (the player on it leaves), then swap, then back in service.
Future<void> placeDevice(BuildContext context, AppState app, GameState s, Hardware hw, int t, String device) async {
  try {
    await app.api!.setDevice(t, device);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$device staat nu op ${s.label(t)}')));
    }
  } on ApiError catch (e) {
    if (!context.mounted) return;
    final locked = e.message.startsWith('409');
    final ok = locked
        ? await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('${s.label(t)} is in gebruik'),
              content: const Text('Tijdens het spel kan een tegel alleen wisselen op een plaats die buiten gebruik '
                  'staat. Nu buiten gebruik zetten (een speler erop gaat uit het spel), wisselen en weer in gebruik nemen?'),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('NEE')),
                FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('JA, WISSEL')),
              ],
            ),
          )
        : false;
    if (ok == true) {
      await app.api!.setEnabled(t, false);
      await app.api!.setDevice(t, device);
      await app.api!.setEnabled(t, true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gewisseld: $device staat nu op ${s.label(t)}')));
      }
    } else if (!locked && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
