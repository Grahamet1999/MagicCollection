import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin client for the parts of the Scryfall API the app uses.
///
/// Scryfall asks clients to send a descriptive User-Agent and Accept header and
/// to rate-limit requests; we set the headers and keep calls user-initiated.
/// See https://scryfall.com/docs/api.
class ScryfallService {
  ScryfallService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _base = 'https://api.scryfall.com';
  static const _headers = {
    'User-Agent': 'MTGCollectionApp/1.0',
    'Accept': 'application/json',
  };

  /// Normalizes a collector number to Scryfall's canonical form: trims
  /// surrounding whitespace and strips leading zeros on purely numeric numbers
  /// (e.g. "001" -> "1"). Non-numeric numbers (e.g. "12a", "★") are left as-is
  /// apart from trimming, so nothing is lost.
  static String normalizeCollectorNumber(String input) {
    final t = input.trim();
    if (RegExp(r'^\d+$').hasMatch(t)) {
      final stripped = t.replaceFirst(RegExp(r'^0+'), '');
      return stripped.isEmpty ? '0' : stripped;
    }
    return t;
  }

  /// Looks up the exact printing identified by [setCode] + [collectorNumber]
  /// via `/cards/:set/:number`. Returns null if not found.
  Future<Map<String, dynamic>?> getBySetAndNumber(
    String setCode,
    String collectorNumber,
  ) async {
    final set = Uri.encodeComponent(setCode.trim().toLowerCase());
    final number =
        Uri.encodeComponent(normalizeCollectorNumber(collectorNumber));
    final uri = Uri.parse('$_base/cards/$set/$number');
    final res = await _client.get(uri, headers: _headers);

    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw ScryfallException(_messageFor(res));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Searches printings by name via `/cards/search`. Uses `unique=prints` so the
  /// caller can pick among the different printings of a card. When
  /// [colorIdentity] is provided (WUBRG letters, or "" for a colorless
  /// commander), results are restricted to that color identity via Scryfall's
  /// `id<=` filter — used when adding to a deck that has a commander. Returns an
  /// empty list when nothing matches (Scryfall replies 404 for no results).
  Future<List<Map<String, dynamic>>> searchByName(
    String query, {
    String? colorIdentity,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    var q = trimmed;
    if (colorIdentity != null) {
      final ci = colorIdentity.isEmpty ? 'c' : colorIdentity.toLowerCase();
      q = '$trimmed id<=$ci';
    }

    final uri = Uri.parse('$_base/cards/search').replace(
      queryParameters: {
        'q': q,
        'unique': 'prints',
        'order': 'released',
        'dir': 'desc',
      },
    );
    final res = await _client.get(uri, headers: _headers);

    if (res.statusCode == 404) return []; // No cards matched.
    if (res.statusCode != 200) {
      throw ScryfallException(_messageFor(res));
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = body['data'] as List<dynamic>? ?? [];
    return data.cast<Map<String, dynamic>>();
  }

  /// Resolves many cards at once via `/cards/collection` (POST). Accepts a list
  /// of identifier maps, each either `{set, collector_number}` or `{name}`, and
  /// returns the found card objects plus the identifiers Scryfall couldn't match.
  /// Requests are chunked to Scryfall's limit of 75 identifiers each.
  Future<ScryfallCollectionResult> getCollection(
    List<Map<String, String>> identifiers,
  ) async {
    final found = <Map<String, dynamic>>[];
    final notFound = <Map<String, dynamic>>[];

    for (var i = 0; i < identifiers.length; i += 75) {
      final end = (i + 75 < identifiers.length) ? i + 75 : identifiers.length;
      final chunk = identifiers.sublist(i, end).map((id) {
        final cn = id['collector_number'];
        if (cn == null) return id;
        return {...id, 'collector_number': normalizeCollectorNumber(cn)};
      }).toList();
      final res = await _client.post(
        Uri.parse('$_base/cards/collection'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'identifiers': chunk}),
      );
      if (res.statusCode != 200) {
        throw ScryfallException(_messageFor(res));
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      found.addAll(
        (body['data'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>(),
      );
      notFound.addAll(
        (body['not_found'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>(),
      );
    }
    return ScryfallCollectionResult(found: found, notFound: notFound);
  }

  String _messageFor(http.Response res) {
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final details = body['details'];
      if (details is String && details.isNotEmpty) return details;
    } catch (_) {
      // Fall through to a generic message.
    }
    return 'Scryfall request failed (HTTP ${res.statusCode}).';
  }

  void dispose() => _client.close();
}

/// Result of a `/cards/collection` batch lookup.
class ScryfallCollectionResult {
  ScryfallCollectionResult({required this.found, required this.notFound});

  /// Matched card objects.
  final List<Map<String, dynamic>> found;

  /// Identifier maps Scryfall could not match (e.g. `{set, collector_number}`).
  final List<Map<String, dynamic>> notFound;
}

class ScryfallException implements Exception {
  ScryfallException(this.message);
  final String message;
  @override
  String toString() => message;
}
