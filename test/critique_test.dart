// Unit tests for the decklist text parser and the critique cut-ranking.
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_collection/models/deck_card.dart';
import 'package:mtg_collection/services/deck_analyzer.dart';
import 'package:mtg_collection/services/deck_critique_service.dart';
import 'package:mtg_collection/services/decklist_parser.dart';

DeckCard card(
  String name, {
  String type = 'Creature',
  double cmc = 2,
  String oracle = '',
  String colorIdentity = '',
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
    );

void main() {
  group('DecklistParser', () {
    test('parses common line formats', () {
      final lines = DecklistParser.parse('''
1 Sol Ring
2x Forest
Lightning Bolt
10 Island
''');
      final byName = {for (final l in lines) l.name: l.quantity};
      expect(byName['Sol Ring'], 1);
      expect(byName['Forest'], 2);
      expect(byName['Lightning Bolt'], 1);
      expect(byName['Island'], 10);
    });

    test('strips set/collector/foil annotations', () {
      final lines = DecklistParser.parse('1 Sol Ring (C21) 263 *F*');
      expect(lines, hasLength(1));
      expect(lines.first.name, 'Sol Ring');
    });

    test('ignores comments, headers, and blank lines', () {
      final lines = DecklistParser.parse('''
// my deck
Commander:
1 Atraxa, Praetors' Voice

# comment
Creatures (1)
''');
      // Only Atraxa is a card; "Creatures (1)" has a leading word not a number
      // — but it is not a real card, so it may resolve to nothing later. The
      // parser keeps it; headers ending in ':' and comments are dropped.
      expect(lines.map((l) => l.name), contains("Atraxa, Praetors' Voice"));
      expect(lines.map((l) => l.name), isNot(contains('Commander')));
    });

    test('merges duplicate names', () {
      final lines = DecklistParser.parse('1 Forest\n1 Forest\n2 Forest');
      expect(lines, hasLength(1));
      expect(lines.first.quantity, 4);
    });

    test('strips SB: sideboard marker', () {
      final lines = DecklistParser.parse('SB: 1 Negate');
      expect(lines.first.name, 'Negate');
    });
  });

  group('DeckCritiqueService.rankCuts', () {
    test('off-color-identity card ranks highest', () {
      final deck = [
        card('Legal Staple', colorIdentity: 'G', oracle: 'draw a card.'),
        card('Off Color Bomb', colorIdentity: 'R', cmc: 6),
      ];
      final analysis =
          DeckAnalyzer.analyze(deck, commanderColorIdentity: 'G');
      final cuts = DeckCritiqueService.rankCuts(deck,
          analysis: analysis, commanderColorIdentity: 'G');
      expect(cuts.first.card.name, 'Off Color Bomb');
      expect(cuts.first.reason, contains('outside color identity'));
    });

    test('low EDHREC inclusion adds to the cut score', () {
      final deck = [card('Pet Card', colorIdentity: 'G', cmc: 6)];
      final analysis = DeckAnalyzer.analyze(deck);
      final cuts = DeckCritiqueService.rankCuts(
        deck,
        analysis: analysis,
        inclusion: {'pet card': 0.01},
      );
      expect(cuts.single.reason, contains('% of decks'));
    });

    test('functional staple with a role is not flagged', () {
      final deck = [
        card('Cultivate',
            type: 'Sorcery',
            cmc: 3,
            oracle:
                'search your library for a basic land card and put it onto the battlefield.'),
      ];
      final analysis = DeckAnalyzer.analyze(deck);
      final cuts = DeckCritiqueService.rankCuts(deck,
          analysis: analysis, inclusion: {'cultivate': 0.4});
      expect(cuts, isEmpty);
    });

    test('lands are never suggested as cuts here', () {
      final deck = [
        card('Command Tower', type: 'Land', oracle: 'add one mana of any color.'),
      ];
      final analysis = DeckAnalyzer.analyze(deck);
      final cuts =
          DeckCritiqueService.rankCuts(deck, analysis: analysis);
      expect(cuts, isEmpty);
    });
  });
}
