// Scanning, back to back (500 visitors a session): the camera keeps running.
// A card is looked up (visitors register with it on the website, synced to
// the control server); fast assign: straight to a free floor tile in this
// gamemaster's colour (the game fills the empty places). Then one indicator
// screen - NAME, go to tile T04, in the colour - and VOLGENDE: the next scan.
// (Also for an unknown card, a full game, ...: what's wrong, VOLGENDE.)
// The recent visitors below the camera follow live (waiting / playing); tap
// one to choose another place (a drone) or cancel. Fast assign off: every
// card opens the visitor page to choose the place.
// MOBIELE SPELER (wheelchair, blind, tablet): choose a free station M1-M5
// (a drone in the game) first, then scan the card: that visitor goes there.
// Above the list: how many tiles and drones are free, every place at a
// glance, and a countdown on tiles in an extermination (when they come free).
// Card codes are never typed: only scanned. A visitor without a phone (at the
// gamemaster's discretion): BEZOEKER ZONDER GSM - name, age and email
// optional - then scan the card they got; an unknown card offers the same.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'api.dart';
import 'app_state.dart';
import 'floor_plan.dart';
import 'model.dart';
import 'theme.dart';
import 'visitor_page.dart';

class _Recent {
  _Recent(this.player, this.code);
  final Player player;
  final String code;
  final DateTime at = DateTime.now();
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key, required this.app});
  final AppState app;
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.normal, detectionTimeoutMs: 400);
  final _recent = <_Recent>[];
  final _seen = <String, DateTime>{};      // card -> last scanned (the same card twice: once)
  bool _busy = false;
  _Recent? _showing;                       // the indicator: this visitor's place ...
  String? _problem;                        // ... or what went wrong
  String? _unknown;                        // the problem: this card is not registered (offer to register it here)
  ({String name, int age, String email})? _newVisitor;   // without a phone: registered with the next scanned card
  int? _station;                           // MOBIELE SPELER: the next scanned card goes to this mobile place (M1-M5)
  Timer? _tick;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.live.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _changed());   // (the "not placed" timeouts)
  }

  @override
  void dispose() {
    app.live.removeListener(_changed);
    _tick?.cancel();
    _scanner.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _show(String problem) => setState(() => _problem = problem);

  /// VOLGENDE: away with the indicator, scan the next card.
  void _next() => setState(() {
        _showing = null;
        _problem = null;
        _unknown = null;
      });

  Future<void> _scanned(String raw) async {
    final code = cardCode(raw);
    if (code == null || _busy || _showing != null || _problem != null) return;
    final last = _seen[code];
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 4)) return;
    _seen[code] = DateTime.now();
    _busy = true;
    try {
      var player = await app.api!.card(code);
      final visitor = _newVisitor;
      if (player != null && visitor != null) {
        _show('Deze kaart is al van ${player.name}.\nScan een nieuwe kaart voor ${visitor.name}.');
        return;
      }
      if (player == null && visitor != null) {   // without a phone: this card is theirs
        player = await app.api!.register(code, visitor.name, visitor.age, visitor.email);
        setState(() => _newVisitor = null);
      }
      if (player == null) {                  // (registering is on the website, synced to the server)
        _seen.remove(code);
        _unknown = code;
        _show('Deze kaart is niet geregistreerd.\nEerst registreren op de website.');
        return;
      }
      await _place(player, code);
    } on ApiError catch (e) {
      _show('$e');
    } finally {
      _busy = false;
    }
  }

  /// Fast assign: a free floor tile, then the indicator (or: choose the place).
  Future<void> _place(Player player, String code) async {
    final where = app.live.state.whereIs(player.id);
      if (where != null) {
        _show('${player.name} staat al op ${app.live.state.label(where.$1)}.');
        return;
      }
      final station = _station;
      if (station != null) {                 // MOBIELE SPELER: to the chosen station
        final s = app.live.state;
        if (!s.open) {
          _show('Het spel is niet open.');
          return;
        }
        if (s.status(station) != PlaceStatus.free) {
          _show('${s.label(station)} is niet meer vrij.\nKies een andere mobiele plaats.');
          setState(() => _station = null);
          return;
        }
        await app.api!.assign(player.id, station, app.gamemaster!);
        setState(() {
          _station = null;
          _showing = _Recent(player, code);
          _recent.insert(0, _showing!);
          if (_recent.length > 30) _recent.removeLast();
        });
        return;
      }
      if (!app.quickAssign) {
        await _scanner.stop();
        if (mounted) {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => VisitorPage(app: app, code: code)));
        }
        if (mounted) await _scanner.start();
        return;
      }
      if (!app.live.state.open) {
        _show('Het spel is niet open.');
        return;
      }
      await app.api!.assign(player.id, 0, app.gamemaster!);
      setState(() {
        _showing = _Recent(player, code);
        _recent.insert(0, _showing!);
        if (_recent.length > 30) _recent.removeLast();
      });
  }

  /// A visitor without a phone: name, age (optional), email (optional).
  Future<({String name, int age, String email})?> _form() async {
    final name = TextEditingController();
    final age = TextEditingController();
    final email = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Retro.panel,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('BEZOEKER ZONDER GSM', style: TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
          const Text('Voor wie zich niet op de website kan registreren.', style: TextStyle(color: Retro.dim)),
          const SizedBox(height: 10),
          TextField(controller: name, autofocus: true, textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Naam')),
          const SizedBox(height: 8),
          TextField(controller: age, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Leeftijd (niet verplicht)')),
          const SizedBox(height: 8),
          TextField(controller: email, keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'E-mail (niet verplicht)')),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () => name.text.trim().isEmpty ? null : Navigator.of(context).pop(true),
            child: const Text('OK'),
          ),
        ]),
      ),
    );
    if (ok != true) return null;
    return (name: name.text.trim(), age: int.tryParse(age.text.trim()) ?? 0, email: email.text.trim());
  }

  /// MOBIELE SPELER: choose a free mobile place (M1-M5); the next scanned card goes there.
  Future<void> _chooseStation() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Retro.panel,
      builder: (context) => ListenableBuilder(
        listenable: app.live,
        builder: (context, _) {
          final s = app.live.state;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('MOBIELE SPELER', style: TextStyle(color: Retro.amber, fontWeight: FontWeight.bold)),
                const Text('Rolstoel, blind, tablet: eerst klaarzetten aan de mobiele plaats. '
                    'Kies de plaats, scan dan de kaart.', style: TextStyle(color: Retro.dim)),
                const SizedBox(height: 10),
                for (final t in s.mobilePlaces) _stationTile(context, s, t),
              ]),
            ),
          );
        },
      ),
    );
    if (picked != null) setState(() => _station = picked);
  }

  Widget _stationTile(BuildContext context, GameState s, int t) {
    final st = s.status(t);
    final free = st == PlaceStatus.free;
    final who = switch (st) {
      PlaceStatus.free => 'VRIJ',
      PlaceStatus.pending => '${s.pending[t]!.name} (wacht)',
      PlaceStatus.playing => s.isDying(t) ? '${s.players[t]!.name}  ·  vrij over ${s.dyingText(t)}' : s.players[t]!.name,
      PlaceStatus.disabled => 'BUITEN GEBRUIK',
    };
    return ListTile(
      enabled: free,
      onTap: free ? () => Navigator.of(context).pop(t) : null,
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        color: free ? Retro.amber : Retro.line,
        child: Text(s.label(t), style: const TextStyle(color: Retro.bg, fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      title: Text(who, style: TextStyle(color: free ? Retro.good : (s.isDying(t) ? Retro.bad : Retro.dim),
          fontWeight: FontWeight.bold)),
    );
  }

  /// How many places are free, every place at a glance (a countdown on the
  /// tiles in an extermination: when they come free).
  Widget _overview(GameState s) {
    final dying = s.dying.values.where((v) => v >= 0).toList()..sort();
    Widget chip(int t) {
      final st = s.status(t);
      final dyingNow = s.isDying(t);
      final Color fill, text;
      if (dyingNow) {
        (fill, text) = (Retro.bad, Retro.cream);
      } else {
        (fill, text) = switch (st) {
          PlaceStatus.free => (Retro.bg, Retro.good),
          PlaceStatus.pending => (s.pending[t]!.color.withOpacity(0.55), Retro.bg),
          PlaceStatus.playing => (Retro.orange.withOpacity(0.45), Retro.cream),
          PlaceStatus.disabled => (Retro.line, Retro.dim),
        };
      }
      final secs = s.dying[t];
      final label = dyingNow ? (secs != null && secs >= 0 ? '$secs' : '☠') : (s.isMobile(t) ? 'M${t - s.floorTiles}' : '$t');
      return Container(
        width: s.isMobile(t) ? 30 : 24,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill,
            border: Border.all(color: st == PlaceStatus.free && !dyingNow ? Retro.good : Colors.transparent)),
        child: Text(label, style: TextStyle(color: text, fontSize: 11, fontWeight: FontWeight.bold)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('VRIJ ', style: TextStyle(color: Retro.dim, fontSize: 13)),
          Text('${s.freeFloor}/${s.enabledFloor} tegels', style: const TextStyle(color: Retro.good, fontWeight: FontWeight.bold)),
          const Text('  ·  ', style: TextStyle(color: Retro.dim)),
          Text('${s.freeMobile}/${s.enabledMobile} mobiel', style: const TextStyle(color: Retro.amber, fontWeight: FontWeight.bold)),
          const Spacer(),
          if (s.dying.isNotEmpty)
            Text(dying.isEmpty ? '☠ ${s.dying.length} komen vrij' : '☠ ${s.dying.length} · eerste over ${dying.first}s',
                style: const TextStyle(color: Retro.bad, fontWeight: FontWeight.bold, fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        if (s.floorPlaces.isNotEmpty) Wrap(spacing: 3, runSpacing: 3, children: [for (final t in s.floorPlaces) chip(t)]),
        const SizedBox(height: 3),
        if (s.mobilePlaces.isNotEmpty) Wrap(spacing: 3, runSpacing: 3, children: [for (final t in s.mobilePlaces) chip(t)]),
      ]),
    );
  }

  /// BEZOEKER ZONDER GSM: the form, then scan the card they got.
  Future<void> _withoutPhone() async {
    final v = await _form();
    if (v != null) setState(() => _newVisitor = v);
  }

  /// An unknown card, registered here after all (at the gamemaster's discretion).
  Future<void> _registerUnknown() async {
    final code = _unknown!;
    final v = await _form();
    if (v == null) return;
    _next();
    try {
      final player = await app.api!.register(code, v.name, v.age, v.email);
      await _place(player, code);
    } on ApiError catch (e) {
      _show('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = app.live.state;
    return Stack(children: [
      _scanning(s),
      if (_showing != null || _problem != null) Positioned.fill(child: _indicator(s)),
    ]);
  }

  /// NAME - go to tile T04 - in this gamemaster's colour; VOLGENDE.
  Widget _indicator(GameState s) {
    final r = _showing;
    final where = r == null ? null : s.whereIs(r.player.id);
    final late = r != null && DateTime.now().difference(r.at) > const Duration(seconds: 6);
    final failed = _problem != null || (where == null && late);
    final color = failed ? Retro.bad : app.color;
    final Widget middle;
    if (_problem != null) {
      middle = Text(_problem!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, color: Retro.cream));
    } else if (where == null) {
      middle = Text(late ? 'Niet geplaatst: geen vrije vloertegel.' : '…', textAlign: TextAlign.center,
          style: TextStyle(fontSize: late ? 26 : 60, color: Retro.cream));
    } else {
      final mobile = s.isMobile(where.$1);
      middle = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(mobile ? 'GA NAAR DRONE' : 'GA NAAR TEGEL',
            style: const TextStyle(fontSize: 24, color: Retro.cream, fontWeight: FontWeight.bold)),
        FittedBox(
          child: Text(s.label(where.$1), style: TextStyle(fontSize: 110, height: 1.05, fontWeight: FontWeight.bold, color: color)),
        ),
        Text(where.$2 ? '✔ DOET MEE' : 'de tegel licht op in deze kleur',
            style: TextStyle(fontSize: 18, color: where.$2 ? Retro.good : Retro.dim)),
      ]);
    }
    return Material(
      color: Retro.bg,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(height: 18, color: color),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (r != null)
                  FittedBox(child: Text(r.player.name.toUpperCase(),
                      style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold, color: Retro.cream))),
                const SizedBox(height: 24),
                middle,
                if (where != null)                   // the plan: where that tile is (the rest of the height)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Center(child: FloorPlan(state: s, highlight: where.$1, highlightColor: app.color,
                          t01Clock: app.t01Clock)),
                    ),
                  ),
              ]),
            ),
          ),
          if (_unknown != null)
            TextButton(
              onPressed: _registerUnknown,
              child: const Text('geen gsm? registreer hier', style: TextStyle(color: Retro.cream, fontSize: 18)),
            ),
          if (r != null && !failed)
            TextButton(
              onPressed: () async {
                final code = r.code;
                _next();
                await _scanner.stop();
                if (mounted) {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => VisitorPage(app: app, code: code)));
                }
                if (mounted) await _scanner.start();
              },
              child: const Text('andere plaats / annuleren', style: TextStyle(color: Retro.dim)),
            ),
          Container(height: 18, color: color),
          SizedBox(
            height: 120,
            child: FilledButton(
              onPressed: _next,
              style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: Retro.bg,
                  shape: const RoundedRectangleBorder()),
              child: const Text('VOLGENDE', style: TextStyle(fontFamily: 'DejaVuSansMono', fontSize: 40, fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _scanning(GameState s) {
    return Column(children: [
      Expanded(
        flex: 3,
        child: Stack(fit: StackFit.expand, children: [
          MobileScanner(
            controller: _scanner,
            onDetect: (c) {
              final raw = c.barcodes.isEmpty ? null : c.barcodes.first.rawValue;
              if (raw != null) _scanned(raw);
            },
            errorBuilder: (context, error, child) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  kIsWeb
                      ? 'Camera niet beschikbaar. Op een iPhone werkt de camera alleen via https '
                          '(zie de handleiding).'
                      : 'Camera niet beschikbaar (${error.errorCode.name}).',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Retro.dim),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(width: 220, height: 220,
                  decoration: BoxDecoration(border: Border.all(color: app.color, width: 4))),
            ),
          ),
          Positioned(
            left: 8, top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              color: Colors.black54,
              child: Text(app.quickAssign ? 'SNEL: VRIJE VLOERTEGEL' : 'PLAATS KIEZEN',
                  style: TextStyle(color: app.color, fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ),
        ]),
      ),
      _overview(s),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: _newVisitor == null && _station == null
            ? Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _withoutPhone,
                    icon: const Icon(Icons.person_add),
                    label: const FittedBox(child: Text('ZONDER GSM')),
                  ),
                ),
                if (s.mobilePlaces.isNotEmpty) const SizedBox(width: 8),
                if (s.mobilePlaces.isNotEmpty) Expanded(
                  child: OutlinedButton.icon(
                    onPressed: s.freeMobile == 0 ? null : _chooseStation,
                    style: OutlinedButton.styleFrom(foregroundColor: Retro.amber,
                        side: BorderSide(color: s.freeMobile == 0 ? Retro.line : Retro.amber)),
                    icon: const Icon(Icons.accessible),
                    label: FittedBox(child: Text(s.freeMobile == 0 ? 'MOBIEL VOL' : 'MOBIELE SPELER')),
                  ),
                ),
              ])
            : Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(border: Border.all(color: _station != null ? Retro.amber : app.color, width: 2)),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      'Scan nu de kaart${_newVisitor != null ? ' van ${_newVisitor!.name}' : ''}'
                      '${_station != null ? '  →  ${s.label(_station!)} (mobiel)' : ''}',
                      style: TextStyle(color: _station != null ? Retro.amber : app.color, fontWeight: FontWeight.bold)),
                  ),
                  TextButton(
                      onPressed: () => setState(() {
                            _newVisitor = null;
                            _station = null;
                          }),
                      child: const Text('annuleer')),
                ]),
              ),
      ),
      Expanded(
        flex: 2,
        child: _recent.isEmpty
            ? const Center(child: Text('Nog niemand toegewezen in deze sessie.', style: TextStyle(color: Retro.dim)))
            : ListView.builder(
                itemCount: _recent.length,
                itemBuilder: (context, i) => _row(s, _recent[i]),
              ),
      ),
    ]);
  }

  Widget _row(GameState s, _Recent r) {
    final where = s.whereIs(r.player.id);
    final late = DateTime.now().difference(r.at) > const Duration(seconds: 6);
    final (text, color) = where == null
        ? (late ? ('✗ niet geplaatst', Retro.bad) : ('…', Retro.dim))
        : where.$2
            ? ('✔ ${s.label(where.$1)}', Retro.good)
            : ('${s.label(where.$1)} wacht', app.color);
    return ListTile(
      dense: true,
      title: Text(r.player.name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(r.code, style: const TextStyle(color: Retro.dim)),
      trailing: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
      onTap: () async {
        await _scanner.stop();
        if (mounted) {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => VisitorPage(app: app, code: r.code)));
        }
        if (mounted) await _scanner.start();
      },
    );
  }
}
