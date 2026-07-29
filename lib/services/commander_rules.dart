import '../models/deck_card.dart';

/// Rules for multi-commander decks — Partner, Friends forever, and
/// "Choose a Background" pairings — plus the combined color identity they form.
///
/// Detection is heuristic (from type line + oracle text) and intentionally
/// permissive: it recognises whether two cards *can* share the command zone,
/// without enforcing every printed restriction (e.g. "Partner with a specific
/// card"). That's the right trade-off for an advisory builder.
class CommanderRules {
  const CommanderRules._();

  static const List<String> _wubrg = ['W', 'U', 'B', 'R', 'G'];

  /// True if [c] has any Partner or Friends-forever ability.
  static bool isPartner(DeckCard c) {
    final o = c.oracleText.toLowerCase();
    return o.contains('partner') || o.contains('friends forever');
  }

  /// True if [c] is a Background enchantment.
  static bool isBackground(DeckCard c) =>
      c.typeLine.toLowerCase().contains('background');

  /// True if [c] can choose a Background ("Choose a Background").
  static bool choosesBackground(DeckCard c) =>
      c.oracleText.toLowerCase().contains('choose a background');

  /// Whether [a] and [b] may legally share the command zone: two partner-capable
  /// commanders, or a "Choose a Background" commander paired with a Background.
  static bool canPair(DeckCard a, DeckCard b) {
    if (choosesBackground(a) && isBackground(b)) return true;
    if (choosesBackground(b) && isBackground(a)) return true;
    if (isPartner(a) && isPartner(b)) return true;
    return false;
  }

  /// The union of the color identities of [commanders], in WUBRG order. Empty
  /// string for an all-colorless command zone.
  static String combinedColorIdentity(Iterable<DeckCard> commanders) {
    final present = <String>{};
    for (final c in commanders) {
      present.addAll(c.colorIdentity.split(''));
    }
    return _wubrg.where(present.contains).join();
  }
}
