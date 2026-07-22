import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/deck_card.dart';
import '../models/mtg_card.dart';
import 'auth_service.dart';
import 'collection_store.dart';
import 'database_service.dart';
import 'deck_store.dart';
import 'firebase_config.dart';

/// Cloud backup/sync of the collection and decks over Firebase Realtime
/// Database REST (same no-plugin approach as [GroupService], so it works on
/// Windows desktop too).
///
/// Local-first: SQLite/SQL Server stays the source of truth on every device.
/// The cloud holds one whole-collection snapshot per user under
/// `users/{uid}/backup` — snapshot-replace semantics, no per-card merging, so
/// there are no conflict or tombstone edge cases. `meta` (timestamp, device,
/// counts) is stored beside `data` so freshness checks don't download the
/// whole payload.
///
/// Pushing happens manually ("Back up now") and automatically: [attach]
/// listens to the stores and, a few quiet seconds after any change, uploads a
/// new snapshot — skipped when its content is identical to the last upload,
/// so browsing/searching (which also notifies) costs nothing. Restoring
/// always asks the user first (see the callers) because it replaces this
/// device's data.
class CloudBackupService {
  CloudBackupService(this._auth, this._db, {http.Client? client})
      : _client = client ?? http.Client();

  final AuthService _auth;
  final DatabaseService _db;
  final http.Client _client;

  CollectionStore? _store;
  DeckStore? _deckStore;
  Timer? _debounce;

  /// JSON of the last pushed/restored payload; identical content is not
  /// re-uploaded by the auto-push path.
  String? _lastSyncedJson;

  /// True while a push or restore is running (also suppresses auto-push).
  bool _busy = false;

  static const _lastSyncPrefKey = 'cloud_backup_last_sync';

  String get _base => FirebaseConfig.databaseUrl;

  Uri _uri(String path, String token) =>
      Uri.parse('$_base/$path.json?auth=$token');

  void dispose() {
    _debounce?.cancel();
    _store?.removeListener(_onLocalChange);
    _deckStore?.removeListener(_onLocalChange);
    _client.close();
  }

  // ---- Auto-push -----------------------------------------------------------

  /// Starts watching the stores; any change (while signed in) schedules a
  /// debounced background push.
  void attach(CollectionStore store, DeckStore deckStore) {
    _store = store;
    _deckStore = deckStore;
    store.addListener(_onLocalChange);
    deckStore.addListener(_onLocalChange);
  }

  void _onLocalChange() {
    if (!_auth.isSignedIn || !FirebaseConfig.isConfigured) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), () {
      // Fire-and-forget; a failed background push just retries on the next
      // change (and the next manual backup reports errors to the user).
      push().catchError((_) => false);
    });
  }

  // ---- Push ----------------------------------------------------------------

  /// Uploads a snapshot of the collection + decks. Returns true when a new
  /// snapshot was uploaded, false when it was skipped (unchanged content or
  /// already busy). Throws on network/auth failure so manual callers can
  /// report it; the auto-push path swallows errors.
  Future<bool> push({bool force = false}) async {
    if (_busy || !_auth.isSignedIn) return false;
    _busy = true;
    try {
      final data = await _buildPayload();
      final encoded = jsonEncode(data);
      if (!force && encoded == _lastSyncedJson) return false;

      final now = DateTime.now().toUtc();
      final uid = _auth.currentUser!.uid;
      final token = await _auth.idToken();
      final res = await _client.put(
        _uri('users/$uid/backup', token),
        body: jsonEncode({
          'meta': {
            'updatedAt': now.toIso8601String(),
            'device': _deviceLabel(),
            'cards': (data['cards'] as List).length,
            'decks': (data['decks'] as List).length,
          },
          'data': data,
        }),
      );
      _check(res);
      _lastSyncedJson = encoded;
      await _saveLastSync(now);
      return true;
    } finally {
      _busy = false;
    }
  }

  /// Serializes everything to an id-free payload: folders travel by name and
  /// cards reference them by name, so ids never need to survive the round
  /// trip (they're reassigned on restore).
  Future<Map<String, dynamic>> _buildPayload() async {
    final folders = await _db.getFolders();
    final folderNames = {for (final f in folders) f.id: f.name};
    final cards = await _db.getCards();
    final decks = await _db.getDecks();

    return {
      'folders': [for (final f in folders) f.name],
      'cards': [
        for (final c in cards)
          {
            ...c.toMap()
              ..remove('id')
              ..remove('folder_id'),
            if (c.folderId != null) 'folder': folderNames[c.folderId],
          },
      ],
      'decks': [
        for (final d in decks)
          {
            'name': d.name,
            if (d.format != null) 'format': d.format,
            'cards': [
              for (final c in await _db.getDeckCards(d.id!))
                c.toMap()
                  ..remove('id')
                  ..remove('deck_id'),
            ],
          },
      ],
    };
  }

  // ---- Meta / freshness ----------------------------------------------------

  /// Fetches the cloud snapshot's metadata (without the payload), or null when
  /// no backup exists yet.
  Future<CloudBackupMeta?> fetchMeta() async {
    if (!_auth.isSignedIn) return null;
    final uid = _auth.currentUser!.uid;
    final token = await _auth.idToken();
    final res = await _client.get(_uri('users/$uid/backup/meta', token));
    _check(res);
    final json = jsonDecode(res.body);
    if (json is! Map) return null;
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    if (updatedAt == null) return null;
    return CloudBackupMeta(
      updatedAt: updatedAt,
      device: json['device'] as String? ?? 'unknown device',
      cards: (json['cards'] as num?)?.toInt() ?? 0,
      decks: (json['decks'] as num?)?.toInt() ?? 0,
    );
  }

  /// True when the cloud snapshot is meaningfully newer than this device's
  /// last push/restore — i.e. another device uploaded since. Null [meta]
  /// means no cloud backup exists.
  Future<bool> cloudIsNewer(CloudBackupMeta? meta) async {
    if (meta == null) return false;
    final last = await _loadLastSync();
    if (last == null) return true; // never synced on this device
    // Small skew allowance so a device's own just-written snapshot doesn't
    // count as "newer".
    return meta.updatedAt.isAfter(last.add(const Duration(seconds: 10)));
  }

  // ---- Restore -------------------------------------------------------------

  /// Downloads the cloud snapshot and replaces this device's collection,
  /// folders, and decks with it. The caller is responsible for having asked
  /// the user first and for reloading the stores afterwards.
  Future<void> restore() async {
    if (_busy) throw CloudBackupException('A sync is already running.');
    if (!_auth.isSignedIn) throw CloudBackupException('Not signed in.');
    _busy = true;
    try {
      final uid = _auth.currentUser!.uid;
      final token = await _auth.idToken();
      final res = await _client.get(_uri('users/$uid/backup', token));
      _check(res);
      final json = jsonDecode(res.body);
      if (json is! Map || json['data'] is! Map) {
        throw CloudBackupException('No cloud backup found.');
      }
      final data = Map<String, dynamic>.from(json['data'] as Map);
      final meta = json['meta'] as Map?;

      // Wipe local data...
      final existingCards = await _db.getCards();
      await _db.deleteCards(
          [for (final c in existingCards) if (c.id != null) c.id!]);
      for (final f in await _db.getFolders()) {
        await _db.deleteFolder(f.id!);
      }
      for (final d in await _db.getDecks()) {
        await _db.deleteDeck(d.id!);
      }

      // ...and rebuild it from the snapshot. Folders first (cards reference
      // them by name).
      final folderIds = <String, int>{};
      for (final name in (data['folders'] as List? ?? const [])) {
        folderIds['$name'] = await _db.getOrCreateFolder('$name');
      }
      for (final raw in (data['cards'] as List? ?? const [])) {
        final map = Map<String, Object?>.from(raw as Map);
        final folderName = map.remove('folder') as String?;
        final card = MtgCard.fromMap(map).copyWith(
          folderId: folderName == null ? null : folderIds[folderName],
        );
        await _db.addCard(card);
      }
      for (final raw in (data['decks'] as List? ?? const [])) {
        final map = Map<String, dynamic>.from(raw as Map);
        final deckId = await _db.addDeck(
          map['name'] as String? ?? 'Untitled',
          map['format'] as String?,
        );
        for (final rawCard in (map['cards'] as List? ?? const [])) {
          final cardMap = Map<String, Object?>.from(rawCard as Map);
          cardMap['deck_id'] = deckId;
          await _db.addOrMergeDeckCard(DeckCard.fromMap(cardMap));
        }
      }

      // The local data now equals the cloud snapshot: remember that so the
      // stores' reload doesn't trigger a pointless auto-push.
      _lastSyncedJson = jsonEncode(await _buildPayload());
      final updatedAt =
          DateTime.tryParse(meta?['updatedAt'] as String? ?? '') ??
              DateTime.now().toUtc();
      await _saveLastSync(updatedAt);
    } finally {
      _busy = false;
    }
  }

  // ---- Helpers -------------------------------------------------------------

  String _deviceLabel() {
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isAndroid) return 'Android device';
    if (Platform.isIOS) return 'iPhone/iPad';
    return Platform.operatingSystem;
  }

  Future<void> _saveLastSync(DateTime when) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncPrefKey, when.toIso8601String());
  }

  Future<DateTime?> _loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    return DateTime.tryParse(prefs.getString(_lastSyncPrefKey) ?? '');
  }

  void _check(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudBackupException('Cloud request failed (${res.statusCode}).');
    }
  }
}

/// Summary of the cloud snapshot (from `users/{uid}/backup/meta`).
class CloudBackupMeta {
  const CloudBackupMeta({
    required this.updatedAt,
    required this.device,
    required this.cards,
    required this.decks,
  });

  final DateTime updatedAt;
  final String device;
  final int cards;
  final int decks;
}

class CloudBackupException implements Exception {
  CloudBackupException(this.message);
  final String message;
  @override
  String toString() => message;
}
