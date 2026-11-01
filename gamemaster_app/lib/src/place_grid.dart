// The places as tiles: T01-T13 around the robot, M1-M5 the mobile players
// (drones), each with who is on it (live). Used to pick a place and to manage
// them.

import 'package:flutter/material.dart';

import 'model.dart';
import 'theme.dart';

class PlaceGrid extends StatelessWidget {
  const PlaceGrid({super.key, required this.state, this.selected, this.selectable, required this.onTap});

  final GameState state;
  final int? selected;
  final bool Function(int tile)? selectable;     // null: every place can be tapped
  final void Function(int tile) onTap;

  @override
  Widget build(BuildContext context) {
    Widget grid(Iterable<int> tiles) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final t in tiles) _place(context, t)],
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Head('VLOERTEGELS'),
      grid([for (var t = 1; t <= state.floorTiles; t++) t]),
      const SizedBox(height: 14),
      const _Head('MOBIEL (DRONE)'),
      grid([for (var t = state.floorTiles + 1; t <= state.places; t++) t]),
    ]);
  }

  Widget _place(BuildContext context, int t) {
    final st = state.status(t);
    final can = selectable?.call(t) ?? true;
    final isSel = selected == t;
    final invite = state.pending[t];
    final player = state.players[t];
    final border = isSel
        ? Retro.amber
        : switch (st) {
            PlaceStatus.playing => Retro.orange,
            PlaceStatus.pending => invite!.color,
            PlaceStatus.disabled => Retro.bad,
            PlaceStatus.free => Retro.line,
          };
    final who = switch (st) {
      PlaceStatus.playing => player!.name,
      PlaceStatus.pending => invite!.name,
      PlaceStatus.disabled => 'BUITEN GEBRUIK',
      PlaceStatus.free => 'VRIJ',
    };
    return Opacity(
      opacity: can ? 1 : 0.4,
      child: InkWell(
        onTap: can ? () => onTap(t) : null,
        child: Container(
          width: 96,
          height: 74,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: isSel ? Retro.amber.withOpacity(0.18) : Retro.panel,
              border: Border.all(color: border, width: isSel ? 3 : 2)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              color: state.isMobile(t) ? Retro.amber : Retro.teal,
              child: Text(state.label(t), style: const TextStyle(color: Retro.bg, fontWeight: FontWeight.bold)),
            ),
            const Spacer(),
            Text(who, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13,
                    color: st == PlaceStatus.free ? Retro.dim : (st == PlaceStatus.pending ? invite!.color : Retro.cream))),
            if (st == PlaceStatus.playing)
              Text('♥' * player!.lives, style: const TextStyle(color: Color(0xFFFF3355), fontSize: 11)),
            if (st == PlaceStatus.pending) const Text('wacht…', style: TextStyle(color: Retro.dim, fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(color: Retro.teal, fontWeight: FontWeight.bold)),
      );
}
