// Unit tests for the EDHREC client (slug + parsing, mocked HTTP) and the
// RecommendationService's hybrid owned/all pools.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:mtg_collection/services/edhrec_service.dart';
import 'package:mtg_collection/services/recommendation_service.dart';

/// A minimal EDHREC commander payload with two categories.
String sampleBody() => jsonEncode({
      'header': 'Test Commander',
      'container': {
        'json_dict': {
          'cardlists': [
            {
              'header': 'High Synergy Cards',
              'tag': 'highsynergycards',
              'cardviews': [
                {
                  'name': 'Synergy Bomb',
                  'num_decks': 900,
                  'potential_decks': 1000,
                  'synergy': 0.5,
                },
                {
                  'name': 'Owned Staple',
                  'num_decks': 500,
                  'potential_decks': 1000,
                  'synergy': 0.2,
                },
              ],
            },
            {
              'header': 'Mana Artifacts',
              'tag': 'manaartifacts',
              'cardviews': [
                {
                  'name': 'Sol Ring',
                  'num_decks': 990,
                  'potential_decks': 1000,
                  'synergy': 0.1,
                },
                {
                  // Malformed entry (no name) — must be skipped, not crash.
                  'num_decks': 10,
                  'potential_decks': 1000,
                },
              ],
            },
          ],
        },
      },
    });

void main() {
  group('EdhrecService.slugify', () {
    test('comma and apostrophe handling', () {
      expect(EdhrecService.slugify("Atraxa, Praetors' Voice"),
          'atraxa-praetors-voice');
    });
    test('apostrophe is dropped, not hyphenated', () {
      expect(EdhrecService.slugify("Urza's Saga"), 'urzas-saga');
    });
    test('collapses punctuation and trims', () {
      expect(EdhrecService.slugify('  Kenrith, the Returned King  '),
          'kenrith-the-returned-king');
    });

    test('slugForCommanders sorts a partner pair alphabetically', () {
      // Order of the input names doesn't matter — EDHREC sorts the slugs.
      const expected = 'thrasios-triton-hero-tymna-the-weaver';
      expect(
          EdhrecService.slugForCommanders(
              ['Tymna the Weaver', 'Thrasios, Triton Hero']),
          expected);
      expect(
          EdhrecService.slugForCommanders(
              ['Thrasios, Triton Hero', 'Tymna the Weaver']),
          expected);
    });
  });

  group('EdhrecService.getCommander', () {
    test('parses cardlists and skips malformed entries', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(),
            'https://json.edhrec.com/pages/commanders/test-commander.json');
        return http.Response(sampleBody(), 200);
      });
      final svc = EdhrecService(client: client);
      final result = await svc.getCommander('Test Commander');
      expect(result, isNotNull);
      expect(result!.cards, hasLength(3)); // the nameless entry is skipped
      final solRing =
          result.cards.firstWhere((c) => c.name == 'Sol Ring');
      expect(solRing.category, 'Mana Artifacts');
      expect(solRing.inclusion, closeTo(0.99, 1e-9));
    });

    test('404 returns null', () async {
      final client = MockClient((req) async => http.Response('', 404));
      final svc = EdhrecService(client: client);
      expect(await svc.getCommander('Nobody'), isNull);
    });

    test('getCommanders fetches the combined partner-pair slug', () async {
      var requestedUrl = '';
      final client = MockClient((req) async {
        requestedUrl = req.url.toString();
        return http.Response(sampleBody(), 200);
      });
      final svc = EdhrecService(client: client);
      await svc.getCommanders(['Tymna the Weaver', 'Thrasios, Triton Hero']);
      expect(
          requestedUrl,
          'https://json.edhrec.com/pages/commanders/'
          'thrasios-triton-hero-tymna-the-weaver.json');
    });

    test('other errors throw', () async {
      final client = MockClient((req) async => http.Response('', 500));
      final svc = EdhrecService(client: client);
      expect(svc.getCommander('X'), throwsA(isA<EdhrecException>()));
    });
  });

  group('RecommendationService.forCommander', () {
    Future<RecommendationResult?> run({
      Set<String> owned = const {},
      Set<String> exclude = const {},
    }) {
      final client = MockClient((req) async => http.Response(sampleBody(), 200));
      final svc = RecommendationService(EdhrecService(client: client));
      return svc.forCommander(
        'Test Commander',
        isOwned: (n) => owned.contains(n),
        excludeNames: exclude,
      );
    }

    test('owned-only pool contains only owned cards', () async {
      final r = await run(owned: {'owned staple', 'sol ring'});
      expect(r!.ownedOnly.map((c) => c.name),
          containsAll(['Sol Ring', 'Owned Staple']));
      expect(r.ownedOnly.every((c) => c.owned), isTrue);
      // Sol Ring (0.99 inclusion) ranks above Owned Staple (0.50).
      expect(r.ownedOnly.first.name, 'Sol Ring');
    });

    test('all pool ranks owned cards first', () async {
      final r = await run(owned: {'owned staple'});
      expect(r!.all.first.owned, isTrue);
      expect(r.all.first.name, 'Owned Staple');
      // Unowned but more popular cards still appear, after owned ones.
      expect(r.all.map((c) => c.name), contains('Sol Ring'));
    });

    test('excludes deck cards and the commander', () async {
      final r = await run(exclude: {'sol ring'});
      expect(r!.all.map((c) => c.name), isNot(contains('Sol Ring')));
    });

    test('null when EDHREC has no page', () async {
      final client = MockClient((req) async => http.Response('', 404));
      final svc = RecommendationService(EdhrecService(client: client));
      expect(await svc.forCommander('X', isOwned: (_) => false), isNull);
    });

    test('forCommanders excludes both commander names and labels the pair',
        () async {
      final body = jsonEncode({
        'container': {
          'json_dict': {
            'cardlists': [
              {
                'header': 'Top Cards',
                'tag': 'topcards',
                'cardviews': [
                  {'name': 'Tymna the Weaver', 'num_decks': 1, 'potential_decks': 1},
                  {'name': 'Sol Ring', 'num_decks': 1, 'potential_decks': 1},
                ],
              },
            ],
          },
        },
      });
      final client = MockClient((req) async => http.Response(body, 200));
      final svc = RecommendationService(EdhrecService(client: client));
      final r = await svc.forCommanders(
        ['Thrasios, Triton Hero', 'Tymna the Weaver'],
        isOwned: (_) => false,
      );
      // The commander itself must not be recommended.
      expect(r!.all.map((c) => c.name), isNot(contains('Tymna the Weaver')));
      expect(r.all.map((c) => c.name), contains('Sol Ring'));
      expect(r.commanderName, 'Thrasios, Triton Hero + Tymna the Weaver');
    });
  });
}
