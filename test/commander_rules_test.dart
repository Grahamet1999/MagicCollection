// Unit tests for multi-commander pairing rules and combined color identity.
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_collection/models/deck_card.dart';
import 'package:mtg_collection/services/commander_rules.dart';

DeckCard card(
  String name, {
  String type = 'Legendary Creature',
  String oracle = '',
  String colorIdentity = '',
}) =>
    DeckCard(
      deckId: 1,
      name: name,
      setCode: 'TST',
      collectorNumber: '1',
      typeLine: type,
      oracleText: oracle,
      colorIdentity: colorIdentity,
      board: DeckBoard.commander,
    );

void main() {
  group('CommanderRules.canPair', () {
    test('two Partner commanders can pair', () {
      final a = card('Thrasios, Triton Hero', oracle: 'partner');
      final b = card('Tymna the Weaver', oracle: 'partner');
      expect(CommanderRules.canPair(a, b), isTrue);
    });

    test('Friends forever commanders can pair', () {
      final a = card('Anara', oracle: 'friends forever');
      final b = card('Yoshimaru', oracle: 'friends forever');
      expect(CommanderRules.canPair(a, b), isTrue);
    });

    test('Choose a Background pairs with a Background', () {
      final a = card('Wilson, Refined Grizzly',
          oracle: 'choose a background');
      final b = card('Raised by Giants',
          type: 'Legendary Enchantment — Background',
          oracle: 'commander creatures you own have base power and toughness 7/7.');
      expect(CommanderRules.canPair(a, b), isTrue);
      // Order-independent.
      expect(CommanderRules.canPair(b, a), isTrue);
    });

    test('a Background does not pair with a non-Background non-chooser', () {
      final bg = card('Raised by Giants',
          type: 'Legendary Enchantment — Background');
      final plain = card('Random Legend');
      expect(CommanderRules.canPair(bg, plain), isFalse);
    });

    test('two plain legends cannot pair', () {
      expect(CommanderRules.canPair(card('A'), card('B')), isFalse);
    });
  });

  group('CommanderRules.combinedColorIdentity', () {
    test('unions identities in WUBRG order', () {
      final a = card('A', colorIdentity: 'G');
      final b = card('B', colorIdentity: 'WB');
      expect(CommanderRules.combinedColorIdentity([a, b]), 'WBG');
    });

    test('colorless pair is empty', () {
      expect(
          CommanderRules.combinedColorIdentity(
              [card('A'), card('B')]),
          '');
    });
  });
}
