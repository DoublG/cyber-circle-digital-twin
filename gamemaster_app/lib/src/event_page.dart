// This event (a fair, a festival): which games are played and which questions
// asked - the gamemasters choose, e.g. a special event with its own questions.
// A new event (control server › Ranglijst) starts with everything as normal.

import 'package:flutter/material.dart';

import 'api.dart';
import 'app_state.dart';
import 'theme.dart';

class EventPage extends StatefulWidget {
  const EventPage({super.key, required this.app, required this.visible});
  final AppState app;
  final bool visible;            // (loaded again every time the tab is opened)
  @override
  State<EventPage> createState() => _EventPageState();
}

class _EventPageState extends State<EventPage> {
  Selection? _sel;
  String? _error;
  bool _busy = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    if (widget.visible) _load();
  }

  @override
  void didUpdateWidget(EventPage old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _load();
  }

  Future<void> _load() => _run(() => widget.app.api!.selection());

  Future<void> _run(Future<Selection> Function() call) async {
    if (widget.app.api == null) return;
    setState(() => _busy = true);
    try {
      final s = await call();
      if (mounted) setState(() { _sel = s; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _game(EventGame g, bool on) {
    final off = {..._sel!.gamesOff};
    on ? off.remove(g.type) : off.add(g.type);
    _run(() => widget.app.api!.setSelection(gamesOff: off.toList()));
  }

  void _questions(Map<int, bool?> change) => _run(() => widget.app.api!.setSelection(questions: change));

  @override
  Widget build(BuildContext context) {
    final sel = _sel;
    if (sel == null) {
      return Center(child: _error != null
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, style: const TextStyle(color: Retro.bad)),
              const SizedBox(height: 10),
              OutlinedButton(onPressed: _load, child: const Text('OPNIEUW')),
            ])
          : const CircularProgressIndicator());
    }
    final q = _search.toLowerCase();
    final shown = sel.questions.where((x) => q.isEmpty || x.question.toLowerCase().contains(q)
        || x.category.toLowerCase().contains(q)).toList();
    final cats = <String, List<EventQuestion>>{};
    for (final x in shown) {
      cats.putIfAbsent(x.category, () => []).add(x);
    }
    final asked = sel.questions.where((x) => x.on).length;
    final changed = sel.questions.where((x) => x.event != null).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(child: Text(sel.eventName.isEmpty ? 'DIT EVENT' : sel.eventName.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
          if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const Text('Geldt voor het hele event, voor alle gamemasters. Een nieuw event begint weer met alles zoals normaal.',
            style: TextStyle(color: Retro.dim)),
        if (_error != null) Text(_error!, style: const TextStyle(color: Retro.bad)),
        const SizedBox(height: 16),
        const Text('SPELLEN', style: TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
        const Text('Uit: nooit gespeeld, ook niet als iemand het in de planning kiest.', style: TextStyle(color: Retro.dim)),
        for (final g in sel.games)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: !g.off,
            onChanged: _busy ? null : (on) => _game(g, on),
            title: Text(g.title, style: TextStyle(color: g.off ? Retro.dim : Retro.cream)),
          ),
        if (sel.games.every((g) => g.off))
          const Text('Alles uit: het spel kiest dan toch zelf een spel.', style: TextStyle(color: Retro.amber)),
        const SizedBox(height: 16),
        const Text('VRAGEN', style: TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
        Text('$asked van ${sel.questions.length} worden gesteld'
            '${changed.isEmpty ? '' : ', ${changed.length} anders dan normaal'}.', style: const TextStyle(color: Retro.dim)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(
            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Zoek een vraag'),
            onChanged: (v) => setState(() => _search = v),
          )),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _busy || changed.isEmpty ? null : () => _questions({for (final x in changed) x.id: null}),
            child: const Text('ALLES NORMAAL'),
          ),
        ]),
        for (final c in cats.entries) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(c.key.isEmpty ? '(geen categorie)' : c.key,
                style: const TextStyle(color: Retro.amber, fontWeight: FontWeight.bold))),
            TextButton(onPressed: _busy ? null : () => _questions({for (final x in c.value) x.id: true}),
                child: const Text('alle aan')),
            TextButton(onPressed: _busy ? null : () => _questions({for (final x in c.value) x.id: false}),
                child: const Text('alle uit')),
          ]),
          for (final x in c.value) _question(x),
        ],
      ]),
    );
  }

  Widget _question(EventQuestion x) => Row(children: [
        Expanded(child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(x.question, style: TextStyle(color: x.on ? Retro.cream : Retro.dim)),
            Text('${x.minAge}–${x.maxAge} jaar · normaal ${x.active ? 'aan' : 'uit'}'
                '${x.event == null ? '' : ' · dit event ${x.event! ? 'AAN' : 'UIT'}'}',
                style: TextStyle(color: x.event == null ? Retro.dim : Retro.amber, fontSize: 12)),
          ]),
        )),
        if (x.event != null)
          IconButton(
            tooltip: 'Zoals normaal',
            icon: const Icon(Icons.undo, size: 20),
            onPressed: _busy ? null : () => _questions({x.id: null}),
          ),
        Switch(value: x.on, onChanged: _busy ? null : (on) => _questions({x.id: on})),
      ]);
}
