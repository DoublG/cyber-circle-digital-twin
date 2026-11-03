// The game space seen from above, as the gamemaster sees it from the
// entrance (at the bottom, 6 o'clock): the robot in the middle, the 13 floor
// tiles around it - T01 at `t01Clock` o'clock (how the circle stands in the
// venue: set up in the control server), then clockwise - and the mobile
// stations M1-M5. Every place shows who is on it (live); `highlight` - the
// visitor just assigned - lights up big in the gamemaster's colour.

import 'dart:math';

import 'package:flutter/material.dart';

import 'model.dart';
import 'theme.dart';

class FloorPlan extends StatelessWidget {
  const FloorPlan({super.key, required this.state, this.highlight, this.highlightColor = Retro.amber,
      this.t01Clock = 12});

  final GameState state;
  /// Where T01 is, as on a clock (the entrance at 6).
  final double t01Clock;
  final int? highlight;
  final Color highlightColor;

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 0.88,                  // (the mobile stations under the entrance)
        child: CustomPaint(painter: _PlanPainter(state, highlight, highlightColor, t01Clock)),
      );
}

class _PlanPainter extends CustomPainter {
  _PlanPainter(this.s, this.highlight, this.color, this.t01Clock);
  final GameState s;
  final int? highlight;
  final Color color;
  final double t01Clock;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.width * 0.47);
    final room = size.width * 0.44;
    final ring = room * 0.68;
    final tileR = room * 0.13;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Retro.line;

    // the play space (fixed), the entrance at the bottom
    canvas.drawCircle(c, room, line..color = Retro.dim);
    final door = c + Offset(0, room);
    canvas.drawLine(door - Offset(room * 0.18, 0), door + Offset(room * 0.18, 0),
        Paint()..color = Retro.orange..strokeWidth = 6);
    _text(canvas, 'INGANG', door + Offset(0, tileR * 0.7), tileR * 0.5, Retro.orange);
    _text(canvas, 'ACHTER', c - Offset(0, room + tileR * 0.05), tileR * 0.42, Retro.dim);

    // cables and the robot
    for (final t in s.floorPlaces) {                          // (only the installed places)
      canvas.drawLine(c, _tile(c, ring, t), Paint()..color = Retro.line..strokeWidth = 1.5);
    }
    canvas.drawCircle(c, tileR * 1.15, Paint()..color = Retro.panel);
    canvas.drawCircle(c, tileR * 1.15, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Retro.teal);
    _text(canvas, 'ROBOT', c, tileR * 0.42, Retro.teal);

    // the floor tiles
    for (final t in s.floorPlaces) {
      _place(canvas, _tile(c, ring, t), tileR, t);
    }
    // the mobile stations: a row under the room
    final mobile = s.mobilePlaces;
    final n = mobile.length;
    for (var k = 0; k < n; k++) {
      final x = size.width / 2 + (k - (n - 1) / 2) * tileR * 2.3;
      _place(canvas, Offset(x, size.height - tileR * 1.05), tileR * 0.85, mobile[k]);
    }
  }

  /// T01 at its hour (12 = straight up), then clockwise (seen from above).
  Offset _tile(Offset c, double r, int t) {
    final a = -pi / 2 + t01Clock * pi / 6 + 2 * pi * (t - 1) / s.floorTiles;
    return c + Offset(cos(a), sin(a)) * r;
  }

  void _place(Canvas canvas, Offset p, double r, int t) {
    final st = s.status(t);
    final lit = t == highlight;
    final invite = s.pending[t];
    final fill = lit
        ? color
        : switch (st) {
            PlaceStatus.playing => s.isDying(t) ? Retro.bad.withOpacity(0.45) : Retro.orange.withOpacity(0.35),
            PlaceStatus.pending => invite!.color.withOpacity(0.45),
            PlaceStatus.disabled => Retro.bad.withOpacity(0.25),
            PlaceStatus.free => Retro.panel,
          };
    final rr = lit ? r * 1.35 : r;
    if (lit) canvas.drawCircle(p, rr * 1.35, Paint()..color = color.withOpacity(0.25));
    if (s.isMobile(t)) {
      final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: rr * 2, height: rr * 1.5), Radius.circular(rr * 0.3));
      canvas.drawRRect(rect, Paint()..color = fill);
      canvas.drawRRect(rect, Paint()..style = PaintingStyle.stroke..strokeWidth = lit ? 4 : 2..color = lit ? Retro.cream : Retro.amber);
    } else {
      canvas.drawCircle(p, rr, Paint()..color = fill);
      canvas.drawCircle(p, rr, Paint()..style = PaintingStyle.stroke..strokeWidth = lit ? 4 : 2
        ..color = lit ? Retro.cream : (st == PlaceStatus.free ? Retro.dim : Retro.orange));
    }
    _text(canvas, s.label(t), p, rr * (lit ? 0.62 : 0.55), lit ? Retro.bg : Retro.cream);
  }

  void _text(Canvas canvas, String text, Offset at, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontFamily: 'DejaVuSansMono', fontSize: size,
          fontWeight: FontWeight.bold, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_PlanPainter old) => true;
}
