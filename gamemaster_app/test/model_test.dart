import 'package:cc_gamemaster/src/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('card codes from a QR code: plain, a link with ?card=, a link with the code at the end', () {
    expect(cardCode(' CC-0042 '), 'CC-0042');
    expect(cardCode('http://192.168.1.10:8080/register?card=CC-0042'), 'CC-0042');
    expect(cardCode('https://cybercircle.be/c/CC-0042'), 'CC-0042');
    expect(cardCode('   '), null);
  });

  test('the setup heart pattern: the place number in binary, heart 1 = 1', () {
    expect(heartPattern(1), '♥♡♡♡♡');
    expect(heartPattern(5), '♥♡♥♡♡');
    expect(heartPattern(13), '♥♡♥♥♡');
    expect(heartPattern(18), '♡♥♡♡♥');
  });

  test('places: T01-T13, then M1-M5', () {
    expect(placeLabel(3), 'T03');
    expect(placeLabel(13), 'T13');
    expect(placeLabel(14), 'M1');
    expect(placeLabel(18), 'M5');
  });

  test('the game state from MQTT', () {
    final s = GameState.fromJson({
      'state': 'SCOREBOARD', 'uitslag': true, 'mode': 'open', 'round': 'Ritme',
      'floor_tiles': 13, 'tile_count': 18,
      'players': [{'tile': 4, 'name': 'Tess', 'lives': 3, 'max_lives': 5, 'out': false}],
      'pending': [{'tile': 15, 'name': 'Mila', 'color': '#ff44cc'}],
      'disabled': [7],
    });
    expect(s.summary, 'UITSLAG: RITME');
    expect(s.status(4), PlaceStatus.playing);
    expect(s.status(15), PlaceStatus.pending);
    expect(s.status(7), PlaceStatus.disabled);
    expect(s.status(1), PlaceStatus.free);
    expect(s.isMobile(15), isTrue);
    expect(s.label(15), 'M2');
    expect(s.open, isTrue);
    expect(s.usedColors, {parseHex('#ff44cc')!.value});
    expect(colorHex(parseHex('#ff44cc')!), '#ff44cc');
  });
}
