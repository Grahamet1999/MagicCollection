import 'deck_card.dart';
import 'scryfall_parse.dart';

/// Functional role a card fills in a deck, derived from its type line and oracle
/// text by [DeckAnalyzer]. A card can fill several roles (a mana dork is both
/// [ramp] and a creature); [land] is exclusive.
enum DeckRole {
  land,
  ramp,

  /// Draws or otherwise digs for cards.
  draw,
  removal,
  wipe,

  /// Puts spells into play cheaply or for free — reanimation, "put … onto the
  /// battlefield", "without paying its mana cost", and cost reducers.
  cheat,

  /// Recurs cards from the graveyard — "play/cast … from your graveyard"
  /// engines (Muldrotha), flashback/escape/disturb-style mechanics, or returning
  /// cards from the graveyard to hand (Regrowth, Eternal Witness). Distinct from
  /// [cheat]: it's card advantage, not acceleration.
  recursion,
}

/// How strongly a [DeckFinding] should be surfaced.
enum FindingSeverity {
  /// Neutral observation (e.g. a stat readout).
  info,

  /// A soft recommendation — the deck works but could be better.
  suggestion,

  /// Something likely wrong (illegal card, far too few lands).
  warning,
}

/// A single piece of advice about a deck, produced by [DeckAnalyzer].
class DeckFinding {
  const DeckFinding({
    required this.severity,
    required this.category,
    required this.message,
    this.cards = const [],
  });

  final FindingSeverity severity;

  /// Short machine-readable bucket, e.g. `lands`, `ramp`, `draw`, `removal`,
  /// `curve`, `legality`. Used for grouping/iconography in the UI.
  final String category;

  /// Human-readable advice sentence.
  final String message;

  /// Names of the cards this finding is about, if any (e.g. the off-color cards
  /// for a legality finding). May be empty.
  final List<String> cards;
}

/// Target counts for a format, used to judge whether a deck is well-rounded.
/// Defaults describe a 100-card singleton Commander deck; other formats can
/// override the numbers.
class DeckFormatProfile {
  const DeckFormatProfile({
    required this.name,
    required this.deckSize,
    required this.baseLands,
    required this.minRamp,
    required this.minDraw,
    required this.minRemoval,
    required this.singleton,
  });

  /// Format label (matches [Deck.format] where possible).
  final String name;

  /// Expected mainboard + commander size by quantity (100 for Commander).
  final int deckSize;

  /// Land count for an average curve before ramp/curve adjustments.
  final int baseLands;

  final int minRamp;
  final int minDraw;
  final int minRemoval;

  /// Whether the format restricts to one copy of each nonbasic card.
  final bool singleton;

  /// Commander/EDH defaults — the app's primary use case.
  static const commander = DeckFormatProfile(
    name: 'Commander',
    deckSize: 100,
    baseLands: 38,
    minRamp: 10,
    minDraw: 8,
    minRemoval: 8,
    singleton: true,
  );

  /// Generic 60-card constructed baseline, used when the deck isn't Commander.
  static const sixty = DeckFormatProfile(
    name: 'Constructed',
    deckSize: 60,
    baseLands: 24,
    minRamp: 0,
    minDraw: 0,
    minRemoval: 0,
    singleton: false,
  );

  /// Picks a profile from a [Deck.format] label; defaults to Commander since
  /// that's what the advanced builder targets.
  static DeckFormatProfile forFormat(String? format) {
    final f = (format ?? '').toLowerCase();
    if (f.contains('commander') || f.contains('edh') || f.contains('brawl')) {
      return commander;
    }
    if (f.isEmpty) return commander;
    return sixty;
  }
}

/// The result of analyzing a deck: category tallies, the mana curve, and a
/// ranked list of [DeckFinding]s. Pure data — produced by [DeckAnalyzer].
class DeckAnalysis {
  const DeckAnalysis({
    required this.profile,
    required this.totalCards,
    required this.landCount,
    required this.rampCount,
    required this.drawCount,
    required this.removalCount,
    required this.wipeCount,
    required this.cheatCount,
    required this.recursionCount,
    required this.creatureCount,
    required this.recommendedLands,
    required this.avgManaValue,
    required this.curve,
    required this.roles,
    required this.findings,
  });

  final DeckFormatProfile profile;

  /// Mainboard + commander count by quantity.
  final int totalCards;

  final int landCount;
  final int rampCount;
  final int drawCount;
  final int removalCount;
  final int wipeCount;

  /// Cards that cheat spells into play or reduce their cost (see [DeckRole.cheat]).
  final int cheatCount;

  /// Cards that recur from the graveyard (see [DeckRole.recursion]).
  final int recursionCount;

  final int creatureCount;

  /// Land count the analyzer recommends for this deck's curve and ramp.
  final int recommendedLands;

  /// Average mana value of non-land cards.
  final double avgManaValue;

  /// CMC histogram of non-land cards, bucketed 0..7 (7 = 7+).
  final Map<int, int> curve;

  /// Every role each card fills, keyed by a stable card key (lowercased name).
  /// Lets the UI badge individual cards as ramp/draw/removal.
  final Map<String, Set<DeckRole>> roles;

  /// Advice, ordered most-severe first.
  final List<DeckFinding> findings;

  /// Convenience: the grouping bucket (Creatures, Lands, …) for a deck card.
  static CardType typeOf(DeckCard c) => primaryType(c.typeLine);
}
