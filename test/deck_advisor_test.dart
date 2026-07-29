// Unit tests for parsing the AI advisor's response contract. The HTTP plumbing
// (auth + POST) mirrors ScryfallService and isn't re-tested here.
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_collection/services/deck_advisor_service.dart';

void main() {
  group('CritiqueAdvice.fromJson', () {
    test('parses overall and verdicts', () {
      final advice = CritiqueAdvice.fromJson({
        'overall': 'Solid list; the big spells are a feature here.',
        'verdicts': [
          {
            'name': 'The Dawning Archaic',
            'verdict': 'keep',
            'reasoning':
                'Free-casts the fat spells your commander surveils into the yard.',
          },
          {'name': 'Filler Vanilla', 'verdict': 'cut', 'reasoning': 'No payoff.'},
        ],
      });
      expect(advice.overall, contains('feature'));
      expect(advice.verdicts, hasLength(2));
      expect(advice.forName('the dawning archaic')?.verdict, 'keep');
    });

    test('parses the free-tier remaining count when present', () {
      final withRemaining = CritiqueAdvice.fromJson({
        'overall': 'ok',
        'remaining': 7,
        'verdicts': const [],
      });
      expect(withRemaining.remaining, 7);
      // BYOK responses omit it → null (unlimited).
      final byok = CritiqueAdvice.fromJson({'overall': 'ok', 'verdicts': const []});
      expect(byok.remaining, isNull);
    });

    test('forName is case-insensitive and returns null when absent', () {
      final advice = CritiqueAdvice.fromJson({
        'overall': '',
        'verdicts': [
          {'name': 'Sol Ring', 'verdict': 'keep', 'reasoning': 'Always.'},
        ],
      });
      expect(advice.forName('SOL RING'), isNotNull);
      expect(advice.forName('Nonexistent'), isNull);
    });

    test('skips malformed verdict entries and defaults missing fields', () {
      final advice = CritiqueAdvice.fromJson({
        'verdicts': [
          {'reasoning': 'no name'}, // dropped
          {'name': 'X'}, // verdict defaults, reasoning empty
          'not a map', // dropped
        ],
      });
      expect(advice.overall, '');
      expect(advice.verdicts, hasLength(1));
      expect(advice.verdicts.single.name, 'X');
      expect(advice.verdicts.single.verdict, 'flex'); // default
      expect(advice.verdicts.single.reasoning, '');
    });
  });
}
