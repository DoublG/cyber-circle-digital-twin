// One place in detail: the physical tile on it (MAC address, online, what it
// told about itself), who plays there, and what the crew can do: kick the
// player out of the game, take the place out of service (decommission) or
// back in, swap the tile for another one (a broken tile), unlink it, light
// it up to find it.

import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'app_state.dart';
import 'model.dart';
import 'theme.dart';
import 'tiles_page.dart';

class TileDetailPage extends StatefulWidget {
  const TileDetailPage({super.key, required this.app, required this.tile});
  final AppState app;
  final int tile;
  @override
  State<TileDetailPage> createState() => _TileDetailPageState();
}

class _TileDetailPageState extends State<TileDetailPage> {
  Hardware? _hw;
  Timer? _poll;

  AppState get app => widget.app;
  int get t => widget.tile;

  @override
  void initState() {
    super.initState();
    app.live.addListener(_changed);
    _load();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    app.live.removeListener(_changed);
    _poll?.cancel();
    super.dispose();
  }

  void _changed() => mounted ? setState(() {}) : null;

  Future<void> _load() async {
    try {
      final hw = await app.api?.hardware();
      if (mounted && hw != null) setState(() => _hw = hw);
    } catch (_) {}
  }

  Future<bool> _sure(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('NEE')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('JA')),
          ],
        ),
      ) ==
      true;

  Future<void> _do(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = app.live.state;
    final hw = _hw;
    final place = hw?.place(t);
    final dev = hw?.device(place?.device);
    final enabled = place?.enabled ?? true;
    final player = s.players[t];
    final invite = s.pending[t];
    final api = app.api!;
    return Scaffold(
      appBar: AppBar(title: Text('${s.isMobile(t) ? 'HANDTEGEL' : 'TEGEL'} ${s.label(t)}')),
      body: hw == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              _section('IN HET SPEL'),
              if (!enabled)
                const Text('BUITEN GEBRUIK: het spel slaat deze plaats over.',
                    style: TextStyle(color: Retro.bad, fontWeight: FontWeight.bold))
              else if (player != null) ...[
                Text(player.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                Text('${'♥' * player.lives}${'♡' * (player.maxLives - player.lives)}${player.out ? '  GEËXTERMINEERD' : ''}',
                    style: const TextStyle(color: Color(0xFFFF3355), fontSize: 20)),
              ] else if (invite != null)
                Text('${invite.name} - wacht op activatie (4 iconen)',
                    style: TextStyle(color: invite.color, fontWeight: FontWeight.bold, fontSize: 18))
              else
                const Text('Vrij', style: TextStyle(color: Retro.dim, fontSize: 18)),
              const SizedBox(height: 10),
              if (player != null || invite != null)
                _button(Icons.logout, player != null ? 'SPELER UIT HET SPEL' : 'UITNODIGING ANNULEREN', Retro.bad, () async {
                  final name = player?.name ?? invite!.name;
                  if (await _sure('$name uit het spel?', '$name verlaat ${s.label(t)} meteen.')) {
                    await _do(() => api.leave(t), '$name is uit het spel');
                  }
                }),
              _button(enabled ? Icons.block : Icons.check_circle, enabled ? 'BUITEN GEBRUIK ZETTEN' : 'WEER IN GEBRUIK NEMEN',
                  enabled ? Retro.bad : Retro.good, () async {
                if (!enabled || await _sure('${s.label(t)} buiten gebruik?',
                    'Het spel slaat deze plaats over; wie erop staat gaat uit het spel. (Een kapotte tegel: daarna wisselen.)')) {
                  await _do(() => api.setEnabled(t, !enabled),
                      enabled ? '${s.label(t)} staat buiten gebruik' : '${s.label(t)} is weer in gebruik');
                }
              }),
              _section('FYSIEKE TEGEL'),
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'In SETUP tonen de harten het nummer: ', style: TextStyle(color: Retro.dim)),
                TextSpan(text: heartPattern(t), style: const TextStyle(color: Color(0xFFFF3355), fontSize: 22, letterSpacing: 4)),
                TextSpan(text: '  ($t, hart 1 bij het logo)', style: const TextStyle(color: Retro.dim)),
              ])),
              const SizedBox(height: 8),
              if (place?.device == null)
                const Text('Geen tegel gekoppeld.', style: TextStyle(color: Retro.dim))
              else ...[
                Row(children: [
                  Icon(Icons.circle, size: 14, color: dev?.online == true ? Retro.good : Retro.bad),
                  const SizedBox(width: 8),
                  Expanded(child: SelectableText(place!.device!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                ]),
                Text(dev == null ? 'nog niet gezien' : (dev.online ? 'online' : 'offline'),
                    style: TextStyle(color: dev?.online == true ? Retro.good : Retro.bad)),
                for (final e in (dev?.info.entries ?? const <MapEntry<String, dynamic>>[]))
                  Text('${e.key}: ${e.value}', style: const TextStyle(color: Retro.dim)),
                const SizedBox(height: 8),
                _button(Icons.lightbulb_outline, 'LAAT OPLICHTEN', Retro.amber,
                    () => _do(() => api.identify(place.device!), '${place.device} licht op')),
              ],
              _button(Icons.swap_horiz, place?.device == null ? 'TEGEL KOPPELEN' : 'TEGEL WISSELEN', Retro.orange,
                  () => _swap(s, hw)),
              if (place?.device != null)
                _button(Icons.link_off, 'TEGEL ONTKOPPELEN', Retro.dim, () async {
                  if (await _sure('Tegel ontkoppelen?', '${place!.device} staat dan op geen plaats meer.')) {
                    await _do(() => api.setDevice(t, ''), '${place.device} ontkoppeld');
                  }
                }),
            ]),
    );
  }

  /// Another tile on this place: one that has no place (a spare).
  Future<void> _swap(GameState s, Hardware hw) async {
    final spares = hw.unplaced;
    final d = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Retro.panel,
      builder: (context) => ListView(padding: const EdgeInsets.all(12), children: [
        Text('WELKE TEGEL OP ${s.label(t)}?', style: const TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
        if (spares.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: Text(
              'Geen losse tegel gevonden. Zet de nieuwe tegel aan: hij meldt zich hier vanzelf (via MQTT).',
              style: TextStyle(color: Retro.dim))),
        for (final d in spares)
          ListTile(
            leading: Icon(Icons.circle, size: 12, color: d.online ? Retro.good : Retro.bad),
            title: Text(d.id),
            trailing: IconButton(icon: const Icon(Icons.lightbulb_outline), onPressed: () => app.api?.identify(d.id)),
            onTap: () => Navigator.of(context).pop(d.id),
          ),
      ]),
    );
    if (d == null || !mounted) return;
    await placeDevice(context, app, s, hw, t, d);
    _load();
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text, style: const TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
      );

  Widget _button(IconData icon, String label, Color color, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, color: color),
            label: Text(label),
            style: OutlinedButton.styleFrom(side: BorderSide(color: color, width: 2), alignment: Alignment.centerLeft),
          ),
        ),
      );
}
