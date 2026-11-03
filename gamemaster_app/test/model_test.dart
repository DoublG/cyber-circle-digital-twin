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

  test('free places and the tiles in an extermination (a countdown till they are free)', () {
    final s = GameState.fromJson({
      'mode': 'open', 'floor_tiles': 13, 'tile_count': 18,
      'players': [
        {'tile': 2, 'name': 'Bram', 'lives': 0, 'max_lives': 5, 'out': true},
        {'tile': 5, 'name': 'Cas', 'lives': 0, 'max_lives': 5, 'out': true},
        {'tile': 14, 'name': 'Mila', 'lives': 2, 'max_lives': 5, 'out': false},
      ],
      'pending': [{'tile': 9, 'name': 'Anna', 'color': '#ff8800'}],
      'disabled': [7],
      'dying': [{'tile': 2, 'free_in': 12}, {'tile': 5, 'free_in': -1}],
    });
    expect(s.isDying(2), isTrue);
    expect(s.isDying(14), isFalse);
    expect(s.dyingText(2), '☠ 12s');
    expect(s.dyingText(5), '☠ …');                 // the robot has not fired yet
    expect(s.freeFloor, 13 - 1 - 2 - 1);            // T07 out of service, T02 + T05 taken, T09 invited
    expect(s.enabledFloor, 12);
    expect(s.freeMobile, 4);
    expect(s.enabledMobile, 5);
  });

  test('a partial installation: only the installed places count', () {
    final s = GameState.fromJson({
      'mode': 'open', 'floor_tiles': 13, 'tile_count': 18,
      'installed': [1, 2, 3, 4, 5, 6, 7, 14, 15],
      'players': [{'tile': 3, 'name': 'Bram', 'lives': 3, 'max_lives': 5, 'out': false}],
    });
    expect(s.floorPlaces, [1, 2, 3, 4, 5, 6, 7]);
    expect(s.mobilePlaces, [14, 15]);
    expect(s.status(9), PlaceStatus.disabled);      // not installed: never free
    expect(s.freeFloor, 6);
    expect(s.enabledFloor, 7);
    expect(s.freeMobile, 2);
    final all = GameState.fromJson({'floor_tiles': 13, 'tile_count': 18});   // (an older game: everything)
    expect(all.floorPlaces.length, 13);
    expect(all.mobilePlaces.length, 5);
  });
}
