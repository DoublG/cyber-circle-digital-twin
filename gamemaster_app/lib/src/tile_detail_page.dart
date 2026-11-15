// One place in detail: the physical tile on it (MAC address, online, what it
// told about itself), who plays there, and what the crew can do: kick the
// player out of the game, take the place out of service (decommission) or
// back in, swap the tile for another one (a broken tile), unlink it, light
// it up to find it. How hard the player on it must press (a small child presses
// lightly): their own %, and the tile's live readings to see how far they get.

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
  Sensitivity? _sens;
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
      final sens = await app.api?.sensitivity();
      if (mounted && sens != null) setState(() => _sens = sens);
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
              if ((player?.playerId ?? invite?.playerId ?? 0) > 0) ..._pressSection(
                  player?.playerId ?? invite!.playerId, player?.name ?? invite!.name, place?.device, dev?.online == true),
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

  /// How hard this player must press: now, the choices (AUTO = by age), measuring.
  List<Widget> _pressSection(int playerId, String name, String? device, bool online) {
    final now = _sens?.places[t];
    final choices = <(String, int?)>[('AUTO', null), ('100 %', 100), ('80 %', 80), ('60 %', 60), ('40 %', 40)];
    final current = now == null ? null : (now.auto ? null : now.press);
    return [
      _section('DRUKGEVOELIGHEID'),
      Text(now?.text ?? '…', style: const TextStyle(fontSize: 16)),
      const Text('Drukt het kind te licht om de iconen te laten werken? Kies een lager %: dan volstaat minder kracht. '
          'Het geldt voor deze speler, ook later op een andere tegel.', style: TextStyle(color: Retro.dim)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (label, v) in choices)
          ChoiceChip(
            label: Text(label),
            selected: now != null && current == v,
            onSelected: (_) => _do(() => app.api!.setPlayerPress(playerId, v),
                v == null ? '$name: automatisch (leeftijd)' : '$name: $v %'),
          ),
      ]),
      if (device != null && online)
        _button(Icons.speed, 'METEN: HOE HARD DRUKT $name?'.toUpperCase(), Retro.teal, () => _measure(device, name)),
    ];
  }

  /// The tile's live readings (60 s): a bar per icon, the threshold - let the child press.
  Future<void> _measure(String device, String name) async {
    final api = app.api!;
    await api.measure(device, 60);
    TileReading? r;
    final best = List.filled(4, 0);
    Timer? timer;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Retro.panel,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        timer ??= Timer.periodic(const Duration(milliseconds: 200), (_) async {
          try {
            final n = await api.reading(device);
            if (n == null || !context.mounted) return;
            for (var i = 0; i < 4 && i < n.counts.length; i++) {
              if (n.counts[i] > best[i]) best[i] = n.counts[i];
            }
            setSheet(() => r = n);
          } catch (_) {}
        });
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${name.toUpperCase()} DRUKT ...', style: const TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(r == null ? 'wacht op de tegel ...' : 'groen = telt als druk · gele streep = drempel (${r!.threshold} %)',
                style: const TextStyle(color: Retro.dim)),
            const SizedBox(height: 12),
            for (var i = 0; i < 4; i++) _meterRow(['VIERKANT', 'DRIEHOEK', 'KRUIS', 'CIRKEL'][i], r, i, best[i]),
            const SizedBox(height: 8),
            Text(_suggest(best, r) ?? 'Laat het kind op elk icoon drukken.', style: const TextStyle(color: Retro.amber)),
          ]),
        );
      }),
    );
    timer?.cancel();
    api.measure(device, 0).catchError((_) {});
  }

  /// What % this child needs: the weakest icon's best press, with a margin (as the web interface).
  String? _suggest(List<int> best, TileReading? r) {
    if (r == null || best.any((b) => b <= 50)) return null;
    final weakest = best.reduce((a, b) => a < b ? a : b);
    final ratio = (weakest * r.threshold / r.press).round();      // % of the threshold at 100 %
    final pct = ((ratio * 0.85) ~/ 5 * 5).clamp(20, 100);
    return 'Zwakste icoon: $ratio % van de drempel → kies $pct %';
  }

  Widget _meterRow(String label, TileReading? r, int i, int best) {
    final c = r == null || i >= r.counts.length ? 0 : r.counts[i];
    final press = r?.press ?? 600;
    final scale = [press * 2, (best * 1.1).round(), 400].reduce((a, b) => a > b ? a : b).toDouble();
    double f(num v) => (v / scale).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            return Stack(children: [
              Container(height: 22, color: Retro.bg),
              Container(height: 22, width: w * f(c), color: c > press ? Retro.good : Retro.dim),
              Positioned(left: w * f(best) - 1, child: Container(width: 2, height: 22, color: Retro.teal)),
              Positioned(left: w * f(press) - 1, top: -2, child: Container(width: 3, height: 26, color: Retro.amber)),
            ]);
          }),
        ),
        SizedBox(width: 56, child: Text('${c < 0 ? 0 : c}', textAlign: TextAlign.right)),
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
