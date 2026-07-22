import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database_service.dart';

/// Permanent on-disk cache of card images, so the collection renders offline
/// and when Scryfall is unreachable.
///
/// Images live as files under `<app-support>/images/`, named by an encoding of
/// their URL — the database stays facts-only (a full collection's images are
/// hundreds of MB, which would bloat the DB and the cloud snapshot). There is
/// no eviction: the cache is bounded by the collection's size, and images are
/// only ever fetched once per device ([CardImage] reads through this cache).
///
/// [warm] runs in the background at startup and after a cloud restore: it
/// scans the collection + decks for images not yet on disk and downloads
/// them, throttled, so a fresh device fills itself without user action.
class CardImageCache {
  CardImageCache._();

  static Directory? _dir;
  static final _client = http.Client();

  /// In-flight/completed resolutions by URL, so a grid of identical printings
  /// downloads each image exactly once.
  static final _pending = <String, Future<ImageProvider>>{};

  static bool _warming = false;

  /// Creates the cache directory. Called once at app start; all other methods
  /// degrade gracefully (straight to network) if this never ran.
  static Future<void> init() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'images'));
      await dir.create(recursive: true);
      _dir = dir;
    } catch (_) {
      _dir = null; // cacheless mode
    }
  }

  /// The cache file for [url] (filename = URL-safe base64 of the URL, so no
  /// hashing collisions and no dependency).
  static File? _fileFor(String url) {
    final dir = _dir;
    if (dir == null) return null;
    final name = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    return File(p.join(dir.path, '$name.img'));
  }

  /// Synchronous fast path: the provider for an already-cached image, or null
  /// when it isn't cached yet (callers then go through [resolve]).
  static ImageProvider? cachedProviderSync(String url) {
    final file = _fileFor(url);
    if (file != null && file.existsSync()) return FileImage(file);
    return null;
  }

  /// Returns a provider for [url]: the cached file when present, otherwise
  /// downloads it, stores it, and serves the file. Falls back to a plain
  /// [NetworkImage] when the cache is unavailable or the write fails.
  static Future<ImageProvider> resolve(String url) {
    return _pending.putIfAbsent(url, () => _resolve(url));
  }

  static Future<ImageProvider> _resolve(String url) async {
    final file = _fileFor(url);
    if (file == null) return NetworkImage(url);
    try {
      if (await file.exists()) return FileImage(file);
      final res = await _client.get(Uri.parse(url));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      // Write via a temp file so a crash mid-write never leaves a truncated
      // image that would then be served forever.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(res.bodyBytes, flush: true);
      await tmp.rename(file.path);
      return FileImage(file);
    } on HttpException {
      _pending.remove(url); // let a later view retry
      rethrow;
    } catch (_) {
      _pending.remove(url);
      // Cache write failed but the network may still work for display.
      return NetworkImage(url);
    }
  }

  /// Background fill: downloads every collection/deck image that isn't on
  /// disk yet. Safe to call repeatedly (no-ops while running; cheap when the
  /// cache is complete). Throttled to stay polite to Scryfall's CDN.
  static Future<void> warm(DatabaseService db) async {
    if (_warming || _dir == null) return;
    _warming = true;
    try {
      final urls = <String>{};
      for (final card in await db.getCards()) {
        final u = card.imageUrl;
        if (u != null && u.isNotEmpty) urls.add(u);
      }
      for (final deck in await db.getDecks()) {
        for (final card in await db.getDeckCards(deck.id!)) {
          final u = card.imageUrl;
          if (u != null && u.isNotEmpty) urls.add(u);
        }
      }
      for (final url in urls) {
        final file = _fileFor(url);
        if (file == null || await file.exists()) continue;
        try {
          await resolve(url);
        } catch (_) {
          // Offline or a bad URL — skip; the next warm pass retries.
        }
        // Modest pacing between downloads.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
      // Background task: never surface errors.
    } finally {
      _warming = false;
    }
  }

  /// Total size of the cache in bytes (for a future "clear cache" UI).
  static Future<int> sizeBytes() async {
    final dir = _dir;
    if (dir == null) return 0;
    var total = 0;
    await for (final f in dir.list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  @visibleForTesting
  static Directory? get directory => _dir;
}
