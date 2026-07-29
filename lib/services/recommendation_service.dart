import 'edhrec_service.dart';

/// One recommended card, combining EDHREC's popularity signals with whether the
/// user owns it.
class CardRecommendation {
  const CardRecommendation({
    required this.name,
    required this.category,
    required this.numDecks,
    required this.potentialDecks,
    required this.synergy,
    required this.owned,
  });

  final String name;

  /// EDHREC category the card came from (e.g. "High Synergy Cards").
  final String category;

  final int numDecks;
  final int potentialDecks;
  final double synergy;

  /// True if the user owns at least one copy in their collection.
  final bool owned;

  /// Fraction of eligible EDHREC decks that include the card (0..1).
  double get inclusion =>
      potentialDecks == 0 ? 0 : numDecks / potentialDecks;
}

/// The hybrid recommendation output the user asked for: an owned-only list and
/// an owned-prioritized-but-not-limited list.
class RecommendationResult {
  const RecommendationResult({
    required this.commanderName,
    required this.ownedOnly,
    required this.all,
  });

  final String commanderName;

  /// Pool A — only cards the user owns, ranked by popularity. "Build it tonight."
  final List<CardRecommendation> ownedOnly;

  /// Pool B — every candidate, owned cards ranked first (then popularity), with
  /// unowned cards flagged via [CardRecommendation.owned] == false.
  final List<CardRecommendation> all;
}

/// Turns EDHREC candidates into ranked recommendations, applying the hybrid
/// owned/all split, ownership flags, and deck/commander exclusions. This is the
/// deterministic orchestration layer; natural-language "why" reasoning is added
/// later by the LLM layer on top of these candidates.
class RecommendationService {
  RecommendationService(this._edhrec);

  final EdhrecService _edhrec;

  /// Fetches and ranks recommendations for a single commander. See
  /// [forCommanders].
  Future<RecommendationResult?> forCommander(
    String commanderName, {
    required bool Function(String nameLower) isOwned,
    Set<String> excludeNames = const {},
    int limit = 60,
  }) =>
      forCommanders([commanderName],
          isOwned: isOwned, excludeNames: excludeNames, limit: limit);

  /// Fetches and ranks recommendations for the deck's commander(s) — one name or
  /// a partner/background pair.
  ///
  /// [isOwned] answers whether a card (lowercased name) is in the collection.
  /// [excludeNames] (lowercased) are cards already in the deck — skipped so we
  /// only ever recommend additions; the commanders' own names are excluded too.
  /// [limit] caps each pool. Returns null when EDHREC has no page.
  Future<RecommendationResult?> forCommanders(
    List<String> commanderNames, {
    required bool Function(String nameLower) isOwned,
    Set<String> excludeNames = const {},
    int limit = 60,
  }) async {
    final data = await _edhrec.getCommanders(commanderNames);
    if (data == null) return null;
    return rankFrom(
      data,
      commanderLabel: commanderNames.join(' + '),
      isOwned: isOwned,
      excludeNames: {
        ...excludeNames,
        ...commanderNames,
      },
      limit: limit,
    );
  }

  /// Ranks already-fetched EDHREC [data] into the hybrid pools, without a network
  /// call. Shared by [forCommanders] and the deck critique so a single EDHREC
  /// fetch powers both the "adds" list and the cut-ranking inclusion map.
  RecommendationResult rankFrom(
    EdhrecCommander data, {
    required String commanderLabel,
    required bool Function(String nameLower) isOwned,
    Set<String> excludeNames = const {},
    int limit = 60,
  }) {
    final excluded = excludeNames.map((e) => e.toLowerCase()).toSet();

    // Dedupe by name, keeping the first (highest-priority) category EDHREC lists
    // the card under.
    final seen = <String>{};
    final recs = <CardRecommendation>[];
    for (final c in data.cards) {
      final key = c.name.toLowerCase();
      if (excluded.contains(key) || !seen.add(key)) continue;
      recs.add(CardRecommendation(
        name: c.name,
        category: c.category,
        numDecks: c.numDecks,
        potentialDecks: c.potentialDecks,
        synergy: c.synergy,
        owned: isOwned(key),
      ));
    }

    // Pool B: owned first, then by inclusion (popularity) descending.
    final all = [...recs]..sort(_ownedThenPopular);
    // Pool A: owned only, by inclusion descending.
    final ownedOnly = recs.where((r) => r.owned).toList()
      ..sort((a, b) => b.inclusion.compareTo(a.inclusion));

    return RecommendationResult(
      commanderName: commanderLabel,
      ownedOnly: ownedOnly.take(limit).toList(),
      all: all.take(limit).toList(),
    );
  }

  /// Sort comparator for pool B: owned cards rank above unowned; within each
  /// group, more-popular (higher inclusion) cards rank first.
  static int _ownedThenPopular(CardRecommendation a, CardRecommendation b) {
    if (a.owned != b.owned) return a.owned ? -1 : 1;
    return b.inclusion.compareTo(a.inclusion);
  }
}
