// Scanning, back to back (500 visitors a session): the camera keeps running.
// A card is looked up (visitors register with it on the website, synced to
// the control server); fast assign: straight to a free floor tile in this
// gamemaster's colour (the game fills the empty places). Then one indicator
// screen - NAME, go to tile T04, in the colour - and VOLGENDE: the next scan.
// (Also for an unknown card, a full game, ...: what's wrong, VOLGENDE.)
// The recent visitors below the camera follow live (waiting / playing); tap
// one to choose another place (a drone) or cancel. Fast assign off: every
// card opens the visitor page to choose the place.
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
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: _newVisitor == null
            ? OutlinedButton.icon(
                onPressed: _withoutPhone,
                icon: const Icon(Icons.person_add),
                label: const Text('BEZOEKER ZONDER GSM'),
              )
            : Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(border: Border.all(color: app.color, width: 2)),
                child: Row(children: [
                  Expanded(child: Text('Scan nu de kaart van ${_newVisitor!.name}',
                      style: TextStyle(color: app.color, fontWeight: FontWeight.bold))),
                  TextButton(onPressed: () => setState(() => _newVisitor = null), child: const Text('annuleer')),
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
