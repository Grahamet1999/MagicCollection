import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin client for EDHREC's public (unofficial) commander JSON, used to fetch
/// "cards played with this commander" recommendations grouped by category.
///
/// The endpoint is `https://json.edhrec.com/pages/commanders/<slug>.json`, where
/// the slug is the commander name sanitized the way EDHREC does it. This is an
/// unofficial API with no stability guarantee, so every access is defensive and
/// a missing/renamed field degrades to a skipped card rather than an error.
class EdhrecService {
  EdhrecService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _base = 'https://json.edhrec.com/pages/commanders';
  static const _headers = {
    'User-Agent': 'MTGCollectionApp/1.0',
    'Accept': 'application/json',
  };

  /// Sanitizes a commander name to EDHREC's slug form: apostrophes are dropped
  /// (so "Urza's Saga" → "urzas-saga"), then every run of other non-alphanumeric
  /// characters becomes a single hyphen (so "Atraxa, Praetors' Voice" →
  /// "atraxa-praetors-voice").
  static String slugify(String name) {
    var s = name.toLowerCase().trim();
    s = s.replaceAll(RegExp("[’']"), ''); // curly + straight apostrophes
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    return s;
  }

  /// Builds the EDHREC page slug for one or more commanders. A single commander
  /// uses its own slug; a partner / background pair uses both slugs joined by a
  /// hyphen in alphabetical order (EDHREC's canonical form, e.g. Thrasios +
  /// Tymna → "thrasios-triton-hero-tymna-the-weaver").
  static String slugForCommanders(List<String> names) {
    final slugs = names.map(slugify).where((s) => s.isNotEmpty).toList()..sort();
    return slugs.join('-');
  }

  /// Fetches recommendations for a single commander. See [getCommanders].
  Future<EdhrecCommander?> getCommander(String commanderName) =>
      getCommanders([commanderName]);

  /// Fetches recommendations for the deck's commander(s) — one name, or two for
  /// a partner / background pair. Returns null when EDHREC has no page (HTTP 404
  /// — unknown/invalid pairing or too few decks), and throws [EdhrecException]
  /// on other transport/format failures.
  Future<EdhrecCommander?> getCommanders(List<String> names) async {
    final slug = slugForCommanders(names);
    if (slug.isEmpty) return null;
    final uri = Uri.parse('$_base/$slug.json');
    final res = await _client.get(uri, headers: _headers);

    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw EdhrecException('EDHREC request failed (HTTP ${res.statusCode}).');
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw EdhrecException('EDHREC returned an unexpected response.');
    }
    return EdhrecCommander.fromJson(slug, body);
  }

  /// Closes the underlying HTTP client.
  void dispose() => _client.close();
}

/// A single card EDHREC associates with a commander, with the popularity signals
/// used to rank recommendations.
class EdhrecCard {
  const EdhrecCard({
    required this.name,
    required this.category,
    required this.tag,
    required this.numDecks,
    required this.potentialDecks,
    required this.synergy,
  });

  /// Card name as it appears on Scryfall (used to resolve printings / ownership).
  final String name;

  /// Human-readable EDHREC category, e.g. "High Synergy Cards", "Mana Artifacts".
  final String category;

  /// Machine tag for the category, e.g. "highsynergycards", "manaartifacts".
  final String tag;

  /// Number of decks running this card with the commander.
  final int numDecks;

  /// Number of decks that could run it (the denominator for inclusion rate).
  final int potentialDecks;

  /// EDHREC synergy score (how much more this card appears here vs. baseline).
  final double synergy;

  /// Fraction of eligible decks that include the card (0..1) — its popularity.
  double get inclusion =>
      potentialDecks == 0 ? 0 : numDecks / potentialDecks;

  /// Parses one `cardviews` entry under a category with [category]/[tag].
  static EdhrecCard? fromJson(
    Map<String, dynamic> json,
    String category,
    String tag,
  ) {
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    return EdhrecCard(
      name: name,
      category: category,
      tag: tag,
      numDecks: (json['num_decks'] as num?)?.toInt() ?? 0,
      potentialDecks: (json['potential_decks'] as num?)?.toInt() ?? 0,
      synergy: (json['synergy'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Parsed EDHREC recommendations for one commander: a flat list of cards across
/// every category, each tagged with the category it came from.
class EdhrecCommander {
  const EdhrecCommander({required this.slug, required this.cards});

  final String slug;
  final List<EdhrecCard> cards;

  /// Reads `container.json_dict.cardlists[]`, flattening each category's
  /// `cardviews[]` into [cards]. Unknown shapes yield an empty list rather than
  /// throwing, since the API is unofficial.
  factory EdhrecCommander.fromJson(String slug, Map<String, dynamic> body) {
    final cards = <EdhrecCard>[];
    final container = body['container'];
    final jsonDict = container is Map ? container['json_dict'] : null;
    final cardlists = jsonDict is Map ? jsonDict['cardlists'] : null;
    if (cardlists is List) {
      for (final entry in cardlists) {
        if (entry is! Map) continue;
        final header = entry['header'] as String? ?? 'Cards';
        final tag = entry['tag'] as String? ?? '';
        final views = entry['cardviews'];
        if (views is! List) continue;
        for (final v in views) {
          if (v is! Map<String, dynamic>) continue;
          final card = EdhrecCard.fromJson(v, header, tag);
          if (card != null) cards.add(card);
        }
      }
    }
    return EdhrecCommander(slug: slug, cards: cards);
  }
}

/// A user-facing error from an EDHREC request.
class EdhrecException implements Exception {
  EdhrecException(this.message);
  final String message;
  @override
  String toString() => message;
}
