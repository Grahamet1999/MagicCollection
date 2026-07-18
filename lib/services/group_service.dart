import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/group.dart';
import '../models/group_card.dart';
import '../models/mtg_card.dart';
import 'auth_service.dart';
import 'firebase_config.dart';

/// Cloud "group binder" over Firebase Realtime Database, accessed purely through
/// its REST + SSE APIs (no FlutterFire plugins, so it works on Windows desktop).
///
/// Data lives under `groups/`, `groupCards/`, `users/`, and `invites/`. Each
/// member writes only their own subtree `groupCards/{gid}/{uid}`; ownership and
/// read access are enforced by Realtime Database security rules (see
/// docs/firebase_setup.md). Group updates arrive live via [streamGroupCards]
/// (server-sent events).
class GroupService {
  GroupService(this._auth, {http.Client? client})
      : _client = client ?? http.Client();

  final AuthService _auth;
  final http.Client _client;

  String get _base => FirebaseConfig.databaseUrl;

  Uri _uri(String path, String token) =>
      Uri.parse('$_base/$path.json?auth=$token');

  Future<dynamic> _get(String path) async {
    final token = await _auth.idToken();
    final res = await _client.get(_uri(path, token));
    _check(res);
    return jsonDecode(res.body);
  }

  Future<void> _put(String path, dynamic data) async {
    final token = await _auth.idToken();
    final res = await _client.put(_uri(path, token), body: jsonEncode(data));
    _check(res);
  }

  Future<void> _patch(String path, dynamic data) async {
    final token = await _auth.idToken();
    final res = await _client.patch(_uri(path, token), body: jsonEncode(data));
    _check(res);
  }

  Future<void> _delete(String path) async {
    final token = await _auth.idToken();
    final res = await _client.delete(_uri(path, token));
    _check(res);
  }

  /// POSTs to a list node; returns the generated push id.
  Future<String> _post(String path, dynamic data) async {
    final token = await _auth.idToken();
    final res = await _client.post(_uri(path, token), body: jsonEncode(data));
    _check(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['name'] as String;
  }

  void _check(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw GroupException('Cloud request failed (${res.statusCode}).');
    }
  }

  // ---- Groups --------------------------------------------------------------

  Future<Group> createGroup(String name) async {
    final user = _auth.currentUser!;
    final code = _generateInviteCode();
    final gid = await _post('groups', {
      'name': name,
      'ownerUid': user.uid,
      'inviteCode': code,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'members': {
        user.uid: {'displayName': user.displayName, 'role': 'owner'},
      },
    });
    await _put('invites/$code', {'groupId': gid});
    await _put('users/${user.uid}/groups/$gid', true);
    return (await _fetchGroup(gid))!;
  }

  Future<Group> joinGroup(String inviteCode) async {
    final code = inviteCode.trim().toUpperCase();
    final invite = await _get('invites/$code');
    if (invite == null) {
      throw GroupException('No group found for that invite code.');
    }
    final gid = (invite as Map)['groupId'] as String;
    final user = _auth.currentUser!;
    await _put('groups/$gid/members/${user.uid}',
        {'displayName': user.displayName, 'role': 'member'});
    await _put('users/${user.uid}/groups/$gid', true);
    return (await _fetchGroup(gid))!;
  }

  Future<List<Group>> myGroups() async {
    final uid = _auth.currentUser!.uid;
    final map = await _get('users/$uid/groups');
    if (map is! Map) return [];
    final groups = <Group>[];
    for (final gid in map.keys) {
      final g = await _fetchGroup(gid as String);
      if (g != null) groups.add(g);
    }
    return groups;
  }

  Future<void> _tryDelete(String path) async {
    try {
      await _delete(path);
    } catch (_) {
      // Best-effort: a denied/failed sub-step must not block the rest.
    }
  }

  Future<void> leaveGroup(String gid) async {
    final uid = _auth.currentUser!.uid;
    await _tryDelete('groupCards/$gid/$uid');
    await _tryDelete('groups/$gid/members/$uid');
    // The essential step — removes the group from *your* list. Always permitted.
    await _delete('users/$uid/groups/$gid');
  }

  /// Deletes a group (owner). Best-effort removes the group record, invite, and
  /// pooled cards for everyone; the final step reliably removes it from the
  /// owner's own list. Orphaned pointers for other members are harmless (they're
  /// skipped when listing groups).
  Future<void> deleteGroup(Group group) async {
    final uid = _auth.currentUser!.uid;
    await _tryDelete('groupCards/${group.id}');
    await _tryDelete('groupCards/${group.id}/$uid');
    await _tryDelete('invites/${group.inviteCode}');
    await _tryDelete('groups/${group.id}');
    // The essential step — always permitted, so the group leaves your view.
    await _delete('users/$uid/groups/${group.id}');
  }

  Future<Group?> _fetchGroup(String gid) async {
    final json = await _get('groups/$gid');
    if (json is! Map) return null;
    return Group.fromRtdb(gid, Map<String, dynamic>.from(json));
  }

  // ---- Publishing my cards -------------------------------------------------

  /// Replaces the signed-in user's published cards in [gid] with a snapshot of
  /// [cards] (their local collection). Re-runnable — this is the "sync my local
  /// collection to the group" action. Does not touch the local collection.
  Future<void> publishCollection(String gid, List<MtgCard> cards) async {
    final uid = _auth.currentUser!.uid;
    final data = <String, dynamic>{
      for (final c in cards) GroupCard.cardKey(c): GroupCard.toRtdb(c),
    };
    await _put('groupCards/$gid/$uid', data);
  }

  Future<void> removeMyCard(String gid, String cardKey) async {
    final uid = _auth.currentUser!.uid;
    await _delete('groupCards/$gid/$uid/$cardKey');
  }

  /// Updates the trade tags on one of the signed-in user's published cards.
  Future<void> setMyCardTags(
    String gid,
    String cardKey,
    List<String> tags,
  ) async {
    final uid = _auth.currentUser!.uid;
    await _patch('groupCards/$gid/$uid/$cardKey', {
      'tags': tags,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ---- Live binder (SSE) ---------------------------------------------------

  /// Streams the group's pooled cards, updating live as members change theirs.
  /// Opens a Realtime Database SSE stream on `groupCards/{gid}` and emits the
  /// full pooled list after each event.
  Stream<List<GroupCard>> streamGroupCards(Group group) async* {
    final token = await _auth.idToken();
    final uri = Uri.parse('$_base/groupCards/${group.id}.json?auth=$token');
    final req = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream';
    final resp = await _client.send(req);

    final names = {for (final m in group.members) m.uid: m.displayName};
    final acc = GroupBinderAccumulator();

    var event = '';
    final data = StringBuffer();
    await for (final line in resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data.write(line.substring(5).trim());
      } else if (line.isEmpty) {
        final payload = data.toString();
        data.clear();
        if ((event == 'put' || event == 'patch') && payload.isNotEmpty) {
          acc.apply(event, jsonDecode(payload) as Map<String, dynamic>);
          yield acc.cards(names);
        }
        event = '';
      }
    }
  }

  static String _generateInviteCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  void dispose() => _client.close();
}

/// Maintains the in-memory `uid -> cardKey -> json` tree from RTDB SSE events.
/// Extracted so the event logic is unit-testable without a live stream.
class GroupBinderAccumulator {
  final Map<String, Map<String, dynamic>> _tree = {};

  void apply(String event, Map<String, dynamic> payload) {
    final path = (payload['path'] as String?) ?? '/';
    final data = payload['data'];
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();

    if (event == 'put') {
      if (parts.isEmpty) {
        _tree.clear();
        if (data is Map) {
          data.forEach((uid, cards) =>
              _tree[uid as String] = _asCardMap(cards));
        }
      } else if (parts.length == 1) {
        final uid = parts[0];
        if (data == null) {
          _tree.remove(uid);
        } else {
          _tree[uid] = _asCardMap(data);
        }
      } else if (parts.length >= 2) {
        final uid = parts[0];
        final key = parts[1];
        final owner = _tree.putIfAbsent(uid, () => {});
        if (data == null) {
          owner.remove(key);
        } else {
          owner[key] = data;
        }
      }
    } else {
      // patch: merge children at the path.
      if (data is! Map) return;
      if (parts.isEmpty) {
        data.forEach((uid, cards) =>
            _tree[uid as String] = _asCardMap(cards));
      } else if (parts.length == 1) {
        final owner = _tree.putIfAbsent(parts[0], () => {});
        data.forEach((k, v) {
          if (v == null) {
            owner.remove(k);
          } else {
            owner[k as String] = v;
          }
        });
      } else if (parts.length >= 2) {
        // Patch of a single card's fields, e.g. a tags edit.
        final owner = _tree.putIfAbsent(parts[0], () => {});
        final key = parts[1];
        final existing = owner[key];
        final merged = existing is Map
            ? Map<String, dynamic>.from(existing)
            : <String, dynamic>{};
        data.forEach((k, v) => merged[k as String] = v);
        owner[key] = merged;
      }
    }
  }

  Map<String, dynamic> _asCardMap(dynamic data) =>
      data is Map ? Map<String, dynamic>.from(data) : {};

  List<GroupCard> cards(Map<String, String> namesByUid) {
    final list = <GroupCard>[];
    _tree.forEach((uid, cards) {
      final name = namesByUid[uid] ?? 'Member';
      cards.forEach((key, json) {
        if (json is Map) {
          list.add(GroupCard.fromRtdb(
            ownerUid: uid,
            ownerName: name,
            key: key,
            json: Map<String, dynamic>.from(json),
          ));
        }
      });
    });
    return list;
  }
}

class GroupException implements Exception {
  GroupException(this.message);
  final String message;
  @override
  String toString() => message;
}
