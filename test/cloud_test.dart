import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mtg_collection/models/group_card.dart';
import 'package:mtg_collection/models/mtg_card.dart';
import 'package:mtg_collection/services/auth_service.dart';
import 'package:mtg_collection/services/group_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GroupBinderAccumulator (SSE)', () {
    test('put root, add, delete, patch', () {
      final acc = GroupBinderAccumulator();

      // Initial snapshot: one card for u1.
      acc.apply('put', {
        'path': '/',
        'data': {
          'u1': {
            'k1': {'name': 'Bolt', 'quantity': 2}
          }
        }
      });
      var cards = acc.cards({'u1': 'Alice'});
      expect(cards.length, 1);
      expect(cards.first.name, 'Bolt');
      expect(cards.first.ownerName, 'Alice');
      expect(cards.first.quantity, 2);

      // Add a second card for u1 via a deep put.
      acc.apply('put', {
        'path': '/u1/k2',
        'data': {'name': 'Island', 'quantity': 1}
      });
      expect(acc.cards({}).length, 2);

      // Delete k1 (put with null data).
      acc.apply('put', {'path': '/u1/k1', 'data': null});
      final after = acc.cards({});
      expect(after.length, 1);
      expect(after.single.name, 'Island');

      // A second member joins via patch.
      acc.apply('patch', {
        'path': '/u2',
        'data': {
          'k3': {'name': 'Forest', 'quantity': 4}
        }
      });
      expect(acc.cards({'u2': 'Bob'}).length, 2);

      // A tags edit arrives as a deep patch (/uid/cardKey) and must merge into
      // the existing card without dropping its other fields.
      acc.apply('patch', {
        'path': '/u2/k3',
        'data': {
          'tags': ['Trade']
        }
      });
      final forest = acc.cards({'u2': 'Bob'}).firstWhere((c) => c.key == 'k3');
      expect(forest.tags, ['Trade']);
      expect(forest.quantity, 4); // other fields preserved
    });
  });

  test('GroupCard round-trip + stable key', () {
    const card = MtgCard(
        name: "Urza's Tower",
        setCode: 'CHR',
        collectorNumber: '116',
        quantity: 3,
        tags: ['Trade']);
    final key = GroupCard.cardKey(card);
    expect(key.contains('.'), false); // RTDB-illegal chars stripped
    final json = GroupCard.toRtdb(card);
    final gc = GroupCard.fromRtdb(
        ownerUid: 'u1', ownerName: 'Alice', key: key, json: json);
    expect(gc.name, "Urza's Tower");
    expect(gc.quantity, 3);
    expect(gc.tags, ['Trade']);
  });

  test('AuthService.signIn hits the right endpoint and persists session',
      () async {
    SharedPreferences.setMockInitialValues({});
    late Uri captured;
    final client = MockClient((req) async {
      captured = req.url;
      return http.Response(
        jsonEncode({
          'localId': 'u1',
          'idToken': 'tok',
          'refreshToken': 'ref',
          'expiresIn': '3600',
          'email': 'a@b.com',
        }),
        200,
      );
    });
    final auth = AuthService(client: client);
    await auth.signIn('a@b.com', 'secret');

    expect(captured.toString(), contains('signInWithPassword'));
    expect(auth.isSignedIn, true);
    expect(auth.currentUser!.uid, 'u1');

    // A fresh AuthService restores the persisted session.
    final auth2 = AuthService(client: client);
    await auth2.restore();
    expect(auth2.isSignedIn, true);
    expect(auth2.currentUser!.email, 'a@b.com');
  });

  test('AuthService surfaces friendly errors', () async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((req) async {
      return http.Response(
        jsonEncode({
          'error': {'message': 'INVALID_LOGIN_CREDENTIALS'}
        }),
        400,
      );
    });
    final auth = AuthService(client: client);
    expect(
      () => auth.signIn('a@b.com', 'wrong'),
      throwsA(isA<AuthException>()),
    );
  });
}
