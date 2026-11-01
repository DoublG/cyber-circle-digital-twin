// Step 2: the visitor of the scanned card (registered on the website) is assigned to a place: any free floor tile (the game picks
// one: no clash with the other gamemasters), a chosen floor tile, or a drone
// (M1-M5) for a mobile player set up at a station. The tile lights up in this
// gamemaster's colour; the page follows it live until the visitor has
// pressed the 4 icons.

import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'app_state.dart';
import 'floor_plan.dart';
import 'model.dart';
import 'place_grid.dart';
import 'theme.dart';

class VisitorPage extends StatefulWidget {
  const VisitorPage({super.key, required this.app, required this.code});
  final AppState app;
  final String code;
  @override
  State<VisitorPage> createState() => _VisitorPageState();
}

class _VisitorPageState extends State<VisitorPage> {
  Player? _player;
  bool _loading = true;
  bool _new = false;               // the card is not registered (yet): register on the website
  String? _error;
  int _place = 0;                  // 0 = any free floor tile
  bool _sending = false;
  DateTime? _assignedAt;           // after assigning: follow it live
  int _asked = 0;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.live.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    app.live.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _load() async {
    try {
      final p = await app.api!.card(widget.code);
      setState(() {
        _player = p;
        _new = p == null;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _assign() async {
    setState(() => _sending = true);
    try {
      await app.api!.assign(_player!.id, _place, app.gamemaster!);
      _asked = _place;
      _assignedAt = DateTime.now();
      Timer(const Duration(seconds: 6), () => mounted ? setState(() {}) : null);   // (then: did it land?)
    } catch (e) {
      _snack('$e');
    }
    setState(() => _sending = false);
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Where this visitor is now: (tile, playing) or null.
  (int, bool)? _where(GameState s) => _player == null ? null : s.whereIs(_player!.id);

  @override
  Widget build(BuildContext context) {
    final s = app.live.state;
    return Scaffold(
      appBar: AppBar(title: Text('KAART ${widget.code}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _message(_error!, Retro.bad)
              : ListView(padding: const EdgeInsets.all(16), children: [
                  if (_new)
                    _message('Kaart ${widget.code} is niet geregistreerd: de bezoeker registreert zich eerst op de '
                        'website met deze kaart.', Retro.bad)
                  else
                    ..._visitor(s),
                ]),
    );
  }

  Widget _message(String text, Color color) =>
      Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text, style: TextStyle(color: color))));

  List<Widget> _visitor(GameState s) {
    final p = _player!;
    final where = _where(s);
    final header = Row(children: [
      Container(width: 14, height: 48, color: app.color),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          Text(p.age > 0 ? '${p.age} jaar' : 'leeftijd onbekend', style: const TextStyle(color: Retro.dim)),
        ]),
      ),
    ]);
    if (where != null) return [header, const SizedBox(height: 24), _following(s, where)];
    final failed = _assignedAt != null && DateTime.now().difference(_assignedAt!) > const Duration(seconds: 5);
    return [
      header,
      if (failed)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(_asked == 0
              ? 'Geen vrije vloertegel gevonden (of het spel is niet open).'
              : '${s.label(_asked)} is net door iemand anders genomen of niet vrij: kies een andere plaats.',
              style: const TextStyle(color: Retro.bad, fontWeight: FontWeight.bold)),
        ),
      if (!s.open)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text('Het spel is niet open (${s.mode.isEmpty ? 'geen verbinding' : s.mode}): toewijzen kan nog niet.',
              style: const TextStyle(color: Retro.amber)),
        ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _place == 0 ? null : () => setState(() => _place = 0),
        icon: Icon(_place == 0 ? Icons.check_box : Icons.check_box_outline_blank),
        label: const Text('VRIJE VLOERTEGEL (het spel kiest)'),
        style: FilledButton.styleFrom(disabledBackgroundColor: Retro.amber, disabledForegroundColor: Retro.bg),
      ),
      const SizedBox(height: 12),
      const Text('of kies een plaats - M1-M5 voor een mobiele speler (eerst klaarzetten aan een station):',
          style: TextStyle(color: Retro.dim)),
      const SizedBox(height: 8),
      PlaceGrid(
        state: s,
        selected: _place == 0 ? null : _place,
        selectable: (t) => s.status(t) == PlaceStatus.free,
        onTap: (t) => setState(() => _place = t),
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _sending || !s.open ? null : _assign,
        child: Text(_place == 0 ? 'TOEWIJZEN AAN EEN VRIJE TEGEL' : 'TOEWIJZEN AAN ${s.label(_place)}'),
      ),
    ];
  }

  /// After the assignment: where to go, until the 4 icons are pressed.
  Widget _following(GameState s, (int, bool) where) {
    final (tile, playing) = where;
    final mobile = s.isMobile(tile);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Retro.panel, border: Border.all(color: playing ? Retro.good : app.color, width: 3)),
      child: Column(children: [
        Text(s.label(tile), style: TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: playing ? Retro.good : app.color)),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320),
            child: FloorPlan(state: s, highlight: tile, highlightColor: app.color, t01Clock: app.t01Clock)),
        const SizedBox(height: 8),
        Text(
          playing
              ? 'DOET MEE ✔'
              : mobile
                  ? 'Drone ${s.label(tile)}: laat de speler aan het station de 4 iconen indrukken.'
                  : 'De tegel licht op in jouw kleur: laat de speler de 4 iconen indrukken.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, color: playing ? Retro.good : Retro.cream),
        ),
        const SizedBox(height: 20),
        if (playing)
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('VOLGENDE BEZOEKER'))
        else
          OutlinedButton(
            onPressed: () async {
              await app.api!.leave(tile);
              setState(() => _assignedAt = null);
            },
            child: const Text('ANNULEER'),
          ),
      ]),
    );
  }
}
