// Unit tests for the cloud layer that don't need a live Firebase backend:
// the SSE accumulator that folds Realtime Database events into the group
// binder, GroupCard serialization, and AuthService's REST calls (mocked).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mtg_collection/models/group.dart';
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

  group('GroupService leave/delete', () {
    Group group({
      required String id,
      required String ownerUid,
      String inviteCode = 'CODE',
      List<GroupMember> members = const [],
    }) =>
        Group(
          id: id,
          name: 'G',
          ownerUid: ownerUid,
          inviteCode: inviteCode,
          members: members,
        );

    test('myGroups keeps live groups and prunes stale pointers', () async {
      final auth = await _signedInAs('me');
      final deleted = <String>[];
      final client = MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/users/me/groups.json') {
          // Pointers to a live group, a deleted one, and one we were removed
          // from.
          return http.Response(
              jsonEncode({'live': true, 'gone': true, 'kicked': true}), 200);
        }
        if (req.method == 'GET' && path == '/groups/live.json') {
          return http.Response(
            jsonEncode({
              'name': 'Live',
              'ownerUid': 'me',
              'inviteCode': 'AAA',
              'members': {
                'me': {'displayName': 'Me', 'role': 'owner'}
              },
            }),
            200,
          );
        }
        // A deleted group and a lost membership both read as forbidden.
        if (req.method == 'GET' &&
            (path == '/groups/gone.json' || path == '/groups/kicked.json')) {
          return http.Response(jsonEncode({'error': 'Permission denied'}), 401);
        }
        if (req.method == 'DELETE') {
          deleted.add(path);
          return http.Response('null', 200);
        }
        return http.Response('null', 200);
      });
      final groups = GroupService(auth, client: client);

      final result = await groups.myGroups();

      expect(result.map((g) => g.id).toList(), ['live']);
      // Both stale pointers pruned; the live one left alone.
      expect(
        deleted,
        containsAll(<String>[
          '/users/me/groups/gone.json',
          '/users/me/groups/kicked.json',
        ]),
      );
      expect(deleted, isNot(contains('/users/me/groups/live.json')));
    });

    test('myGroups keeps the pointer on a transient error', () async {
      final auth = await _signedInAs('me');
      final deleted = <String>[];
      final client = MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/users/me/groups.json') {
          return http.Response(jsonEncode({'g1': true}), 200);
        }
        if (req.method == 'GET' && path == '/groups/g1.json') {
          return http.Response('server error', 500); // transient, not "gone"
        }
        if (req.method == 'DELETE') {
          deleted.add(path);
          return http.Response('null', 200);
        }
        return http.Response('null', 200);
      });
      final groups = GroupService(auth, client: client);

      final result = await groups.myGroups();

      expect(result, isEmpty); // couldn't load it this time…
      expect(deleted, isEmpty); // …but the pointer is kept for a retry
    });

    test('deleteGroup removes shared data then the owner pointer, in order',
        () async {
      final auth = await _signedInAs('me');
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        return http.Response('null', 200);
      });
      final groups = GroupService(auth, client: client);

      await groups.deleteGroup(group(
        id: 'g1',
        ownerUid: 'me',
        inviteCode: 'CODE',
        members: [GroupMember(uid: 'me', displayName: 'Me', role: 'owner')],
      ));

      expect(calls, [
        'DELETE /groupCards/g1.json',
        'DELETE /invites/CODE.json',
        'DELETE /groups/g1.json',
        'DELETE /users/me/groups/g1.json',
      ]);
    });

    test('leaveGroup removes cards, membership, then pointer, in order',
        () async {
      final auth = await _signedInAs('me');
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        return http.Response('null', 200);
      });
      final groups = GroupService(auth, client: client);

      await groups.leaveGroup(group(
        id: 'g1',
        ownerUid: 'owner',
        members: [
          GroupMember(uid: 'owner', displayName: 'O', role: 'owner'),
          GroupMember(uid: 'me', displayName: 'Me', role: 'member'),
        ],
      ));

      expect(calls, [
        'DELETE /groupCards/g1/me.json',
        'DELETE /groups/g1/members/me.json',
        'DELETE /users/me/groups/g1.json',
      ]);
    });

    test('leaveGroup refuses when the caller is the owner', () async {
      final auth = await _signedInAs('me');
      final client = MockClient((req) async => http.Response('null', 200));
      final groups = GroupService(auth, client: client);

      expect(
        () => groups.leaveGroup(group(
          id: 'g1',
          ownerUid: 'me',
          members: [GroupMember(uid: 'me', displayName: 'Me', role: 'owner')],
        )),
        throwsA(isA<GroupException>()),
      );
    });

    test('deleteGroup refuses when the caller is not the owner', () async {
      final auth = await _signedInAs('me');
      final client = MockClient((req) async => http.Response('null', 200));
      final groups = GroupService(auth, client: client);

      expect(
        () => groups.deleteGroup(group(id: 'g1', ownerUid: 'someone-else')),
        throwsA(isA<GroupException>()),
      );
    });
  });
}

/// Builds an [AuthService] already signed in as [uid], backed by a mock that
/// answers the sign-in call. The id token is cached with a future expiry, so no
/// further network calls are made when a [GroupService] asks for it.
Future<AuthService> _signedInAs(String uid) async {
  SharedPreferences.setMockInitialValues({});
  final client = MockClient((req) async => http.Response(
        jsonEncode({
          'localId': uid,
          'idToken': 'tok',
          'refreshToken': 'ref',
          'expiresIn': '3600',
          'email': '$uid@example.com',
        }),
        200,
      ));
  final auth = AuthService(client: client);
  await auth.signIn('$uid@example.com', 'pw');
  return auth;
}
