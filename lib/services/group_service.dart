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

  /// Like [_get] but returns the HTTP status alongside the decoded body and
  /// never throws — used where the caller must tell "the resource is gone or
  /// forbidden" (which it should act on) apart from "a transient error" (which
  /// it should ignore). A network/auth failure is reported as status `0`.
  Future<({int status, dynamic body})> _getRaw(String path) async {
    try {
      final token = await _auth.idToken();
      final res = await _client.get(_uri(path, token));
      dynamic body;
      try {
        body = jsonDecode(res.body);
      } catch (_) {
        body = null; // non-JSON error body
      }
      return (status: res.statusCode, body: body);
    } catch (_) {
      return (status: 0, body: null);
    }
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

  /// Lists the groups the signed-in user belongs to, self-healing stale state.
  ///
  /// `users/{uid}/groups` is only a list of pointers; the source of truth for
  /// membership is each `groups/{gid}` record. A pointer can outlive what it
  /// points to — the owner deleted the group, or you were removed — and the
  /// security rules deny reading a group you're no longer a member of, so those
  /// reads come back forbidden or absent. When that happens we prune the
  /// dangling pointer here so the group stops reappearing. Transient failures
  /// (no network, 5xx) are left untouched so a blip never drops a valid group.
  Future<List<Group>> myGroups() async {
    final uid = _auth.currentUser!.uid;
    final pointers = await _get('users/$uid/groups');
    if (pointers is! Map) return [];

    final groups = <Group>[];
    for (final gid in pointers.keys.cast<String>()) {
      final res = await _getRaw('groups/$gid');

      // A readable group record means we're a member (reads require it), so the
      // pointer is valid — keep it.
      if (res.status == 200 && res.body is Map) {
        groups.add(
          Group.fromRtdb(gid, Map<String, dynamic>.from(res.body as Map)),
        );
        continue;
      }

      // Definitively gone or forbidden → the pointer is stale, so remove it.
      // 200-with-null = the group was deleted; 401/403 = we're no longer a
      // member; 404 = it never existed. Anything else (0/5xx) is transient and
      // deliberately left in place to retry on the next load.
      if (_pointerIsStale(res.status)) {
        await _tryDelete('users/$uid/groups/$gid');
      }
    }
    return groups;
  }

  /// Whether a failed `groups/{gid}` read means the pointer to it should be
  /// pruned: the group is gone (200-with-null / 404) or reading it is forbidden
  /// because we're no longer a member (401/403). Transient statuses are not.
  static bool _pointerIsStale(int status) =>
      status == 200 || status == 401 || status == 403 || status == 404;

  /// Deletes [path], swallowing any error. For cleanup steps that must not block
  /// the essential removal that follows them — a denied or already-gone node is
  /// fine either way. (RTDB returns 200 for deleting a path that doesn't exist.)
  Future<void> _tryDelete(String path) async {
    try {
      await _delete(path);
    } catch (_) {
      // Best-effort: a denied/failed sub-step must not block the rest.
    }
  }

  /// Removes the signed-in user from [group] (a member leaving on their own).
  ///
  /// Not for owners: an owner leaving would orphan the group (no one could then
  /// delete it), so this throws and directs them to [deleteGroup] instead.
  ///
  /// The steps run in the only order the rules allow — your pooled cards can be
  /// deleted only *while* you're still a member, so they go first; then your
  /// membership; then your personal pointer. The pointer delete is the
  /// essential, always-permitted step that removes the group from your list, so
  /// it runs last and is the only one allowed to surface an error. Even if it
  /// somehow failed, [myGroups] would prune the now-unreadable group next load.
  Future<void> leaveGroup(Group group) async {
    final uid = _auth.currentUser!.uid;
    if (group.ownerUid == uid) {
      throw GroupException('You own this group — delete it instead of leaving.');
    }
    await _tryDelete('groupCards/${group.id}/$uid');     // 1. your pooled cards
    await _tryDelete('groups/${group.id}/members/$uid'); // 2. your membership
    await _delete('users/$uid/groups/${group.id}');      // 3. your pointer
  }

  /// Deletes a group the signed-in user owns.
  ///
  /// Removes everything the owner is permitted to touch — every member's pooled
  /// cards, the invite code, and the group record — then the owner's own
  /// pointer (the essential, always-permitted step). Order matters: the pooled
  /// cards must be deleted *before* the group record, because the rule that
  /// authorizes deleting `groupCards/{gid}` reads the group's `ownerUid`, which
  /// is gone once the group record is deleted.
  ///
  /// The owner can't delete other members' personal pointers (the rules only
  /// let each user write under their own uid). Those self-heal: the next time
  /// each member loads, [myGroups] finds the group unreadable and prunes the
  /// pointer. Throws for a non-owner (their delete would be denied anyway).
  Future<void> deleteGroup(Group group) async {
    final uid = _auth.currentUser!.uid;
    if (group.ownerUid != uid) {
      throw GroupException('Only the group owner can delete it.');
    }
    await _tryDelete('groupCards/${group.id}');      // 1. everyone's pooled cards
    await _tryDelete('invites/${group.inviteCode}'); // 2. the invite code
    await _tryDelete('groups/${group.id}');          // 3. the group record
    await _delete('users/$uid/groups/${group.id}');  // 4. owner's pointer
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

    // Parse the text/event-stream: accumulate `event:` and `data:` lines until
    // a blank line ends the event, then fold it into the accumulator and emit
    // the refreshed pooled list.
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

  /// Generates a random 6-character invite code. The alphabet omits easily
  /// confused characters (0/O, 1/I) so codes are easy to read out loud.
  static String _generateInviteCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Closes the underlying HTTP client.
  void dispose() => _client.close();
}

/// Maintains the in-memory `uid -> cardKey -> json` tree from RTDB SSE events.
/// Extracted so the event logic is unit-testable without a live stream.
class GroupBinderAccumulator {
  final Map<String, Map<String, dynamic>> _tree = {};

  /// Folds one RTDB SSE event into [_tree].
  ///
  /// [event] is `put` (replace the subtree at the path) or `patch` (merge
  /// children). [payload] carries a `path` relative to `groupCards/{gid}` and
  /// the new `data`. The path depth selects the scope: root replaces everyone,
  /// one segment a member's whole card set, two a single card. A null `data`
  /// means the node was deleted.
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

  /// Coerces an untyped SSE value into a `cardKey -> json` map (empty if it
  /// isn't a map).
  Map<String, dynamic> _asCardMap(dynamic data) =>
      data is Map ? Map<String, dynamic>.from(data) : {};

  /// Flattens the current tree into a [GroupCard] list, attaching each owner's
  /// display name from [namesByUid].
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

/// A user-facing error from a cloud group operation.
class GroupException implements Exception {
  GroupException(this.message);
  final String message;
  @override
  String toString() => message;
}
