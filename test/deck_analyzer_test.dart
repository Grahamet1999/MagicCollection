// Unit tests for the offline DeckAnalyzer: role classification from oracle text
// and the shortfall findings it produces against the Commander profile.
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_collection/models/deck_advice.dart';
import 'package:mtg_collection/models/deck_card.dart';
import 'package:mtg_collection/services/deck_analyzer.dart';

/// Builds a mainboard [DeckCard] with just the fields the analyzer reads.
DeckCard card(
  String name, {
  String type = 'Creature',
  double cmc = 2,
  String oracle = '',
  String colorIdentity = '',
  int quantity = 1,
  String board = DeckBoard.main,
}) =>
    DeckCard(
      deckId: 1,
      name: name,
      setCode: 'TST',
      collectorNumber: '1',
      typeLine: type,
      cmc: cmc,
      oracleText: oracle,
      colorIdentity: colorIdentity,
      quantity: quantity,
      board: board,
    );

void main() {
  group('rolesOf', () {
    test('lands are land-only even if they tap for mana', () {
      final r = DeckAnalyzer.rolesOf('basic land — forest', 'tap: add {g}.');
      expect(r, {DeckRole.land});
    });

    test('mana dork is ramp', () {
      final r = DeckAnalyzer.rolesOf(
          'creature — elf druid', '{t}: add {g}.');
      expect(r.contains(DeckRole.ramp), isTrue);
    });

    test('land-fetch ramp', () {
      final r = DeckAnalyzer.rolesOf('sorcery',
          'search your library for a basic land card and put it onto the battlefield tapped.');
      expect(r.contains(DeckRole.ramp), isTrue);
    });

    test('card draw', () {
      expect(DeckAnalyzer.rolesOf('sorcery', 'draw two cards.')
          .contains(DeckRole.draw), isTrue);
      expect(DeckAnalyzer.rolesOf('sorcery', 'investigate.')
          .contains(DeckRole.draw), isTrue);
    });

    test('spot removal', () {
      expect(DeckAnalyzer.rolesOf('instant', 'destroy target creature.')
          .contains(DeckRole.removal), isTrue);
      expect(DeckAnalyzer.rolesOf('instant', 'counter target spell.')
          .contains(DeckRole.removal), isTrue);
    });

    test('board wipe counts as wipe and removal', () {
      final r = DeckAnalyzer.rolesOf('sorcery', 'destroy all creatures.');
      expect(r.contains(DeckRole.wipe), isTrue);
      expect(r.contains(DeckRole.removal), isTrue);
    });

    test('vanilla creature has no functional role', () {
      expect(DeckAnalyzer.rolesOf('creature — bear', ''), isEmpty);
    });

    test('extra land drop counts as ramp', () {
      final r = DeckAnalyzer.rolesOf('enchantment',
          'you may play an additional land on each of your turns.');
      expect(r.contains(DeckRole.ramp), isTrue);
    });

    test('put-land-from-hand counts as ramp', () {
      final r = DeckAnalyzer.rolesOf('enchantment',
          'whenever you play a land, you may put another land card from your hand onto the battlefield.');
      expect(r.contains(DeckRole.ramp), isTrue);
    });

    test('reanimation counts as cheat, not removal', () {
      final r = DeckAnalyzer.rolesOf('sorcery',
          'return target creature card from your graveyard to the battlefield.');
      expect(r.contains(DeckRole.cheat), isTrue);
      expect(r.contains(DeckRole.removal), isFalse);
    });

    test('free cast counts as cheat', () {
      final r = DeckAnalyzer.rolesOf('enchantment',
          "you may put a creature card from your hand onto the battlefield. that creature gains haste.");
      expect(r.contains(DeckRole.cheat), isTrue);
    });

    test('without paying mana cost counts as cheat', () {
      final r = DeckAnalyzer.rolesOf('sorcery',
          'you may cast it without paying its mana cost.');
      expect(r.contains(DeckRole.cheat), isTrue);
    });

    test('cost reducer counts as cheat', () {
      final r = DeckAnalyzer.rolesOf('creature — wizard',
          'creature spells you cast cost {1} less to cast.');
      expect(r.contains(DeckRole.cheat), isTrue);
    });

    test('land ramp is not miscounted as cheat', () {
      final r = DeckAnalyzer.rolesOf('sorcery',
          'search your library for a basic land card and put it onto the battlefield tapped.');
      expect(r.contains(DeckRole.ramp), isTrue);
      expect(r.contains(DeckRole.cheat), isFalse);
    });

    test('cast-from-graveyard engine is recursion (Muldrotha)', () {
      final r = DeckAnalyzer.rolesOf('legendary creature — elemental',
          'during each of your turns, you may play a land and cast a permanent spell of each permanent type from your graveyard.');
      expect(r.contains(DeckRole.recursion), isTrue);
      expect(r.contains(DeckRole.cheat), isFalse);
    });

    test('return-to-hand is recursion (Regrowth)', () {
      final r = DeckAnalyzer.rolesOf(
          'sorcery', 'return target card from your graveyard to your hand.');
      expect(r.contains(DeckRole.recursion), isTrue);
    });

    test('graveyard keyword mechanics are recursion', () {
      expect(
          DeckAnalyzer.rolesOf('instant', 'draw a card.\nflashback {3}{u}')
              .contains(DeckRole.recursion),
          isTrue);
      expect(
          DeckAnalyzer.rolesOf('sorcery', 'escape—{2}{b}{b}, exile four cards.')
              .contains(DeckRole.recursion),
          isTrue);
    });

    test('reanimation-to-battlefield stays cheat, not recursion', () {
      final r = DeckAnalyzer.rolesOf('sorcery',
          'return target creature card from your graveyard to the battlefield.');
      expect(r.contains(DeckRole.cheat), isTrue);
      expect(r.contains(DeckRole.recursion), isFalse);
    });
  });

  group('analyze', () {
    test('counts tally by quantity and land bucket is exclusive', () {
      final deck = [
        card('Forest',
            type: 'Basic Land — Forest', oracle: 'tap: add {g}.', quantity: 10),
        card('Llanowar Elves',
            type: 'Creature — Elf', cmc: 1, oracle: '{t}: add {g}.'),
        card('Divination', type: 'Sorcery', cmc: 3, oracle: 'draw two cards.'),
      ];
      final a = DeckAnalyzer.analyze(deck);
      expect(a.landCount, 10);
      expect(a.rampCount, 1); // the dork, not the land
      expect(a.drawCount, 1);
      expect(a.totalCards, 12);
    });

    test('tallies cheat effects and reports them', () {
      final deck = [
        card('Reanimate',
            type: 'Sorcery',
            cmc: 1,
            oracle:
                'return target creature card from your graveyard to the battlefield.'),
        card('Sneak Attack',
            type: 'Enchantment',
            cmc: 4,
            oracle:
                '{r}: put a creature card from your hand onto the battlefield.'),
      ];
      final a = DeckAnalyzer.analyze(deck);
      expect(a.cheatCount, 2);
      expect(a.findings.any((f) => f.category == 'cheat'), isTrue);
    });

    test('tallies recursion effects and reports them', () {
      final deck = [
        card('Regrowth',
            type: 'Sorcery',
            cmc: 2,
            oracle: 'return target card from your graveyard to your hand.'),
        card('Muldrotha, the Gravetide',
            type: 'Legendary Creature — Elemental',
            cmc: 6,
            oracle:
                'you may play a land and cast a permanent spell of each permanent type from your graveyard.'),
      ];
      final a = DeckAnalyzer.analyze(deck);
      expect(a.recursionCount, 2);
      expect(a.findings.any((f) => f.category == 'recursion'), isTrue);
    });

    test('flags off-color-identity cards', () {
      final deck = [
        card('Legal Card', colorIdentity: 'G'),
        card('Splashy Bolt', colorIdentity: 'R'),
      ];
      final a =
          DeckAnalyzer.analyze(deck, commanderColorIdentity: 'G');
      final legality =
          a.findings.where((f) => f.category == 'legality').toList();
      expect(legality, hasLength(1));
      expect(legality.first.severity, FindingSeverity.warning);
      expect(legality.first.cards, contains('Splashy Bolt'));
    });

    test('warns when far short on lands', () {
      // 5 lands in a would-be Commander deck → strong warning.
      final deck = [
        for (var i = 0; i < 5; i++)
          card('Island $i', type: 'Basic Land — Island'),
        for (var i = 0; i < 30; i++) card('Spell $i', cmc: 4),
      ];
      final a = DeckAnalyzer.analyze(deck);
      final landFinding =
          a.findings.firstWhere((f) => f.category == 'lands');
      expect(landFinding.severity, FindingSeverity.warning);
      expect(a.recommendedLands, greaterThan(a.landCount));
    });

    test('findings are ordered most-severe first', () {
      final deck = [card('Only Card', colorIdentity: 'R')];
      final a = DeckAnalyzer.analyze(deck, commanderColorIdentity: '');
      for (var i = 1; i < a.findings.length; i++) {
        expect(a.findings[i - 1].severity.index,
            greaterThanOrEqualTo(a.findings[i].severity.index));
      }
    });
  });
}
