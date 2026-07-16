/// Shared helpers for reading fields out of a Scryfall card JSON object,
/// used by both [MtgCard] and [DeckCard]. Handles double-faced cards by falling
/// back to the front face where a field lives under `card_faces`.
library;

const List<String> _wubrg = ['W', 'U', 'B', 'R', 'G'];

/// Card colors in WUBRG order, e.g. "W", "WU", or "" for colorless.
String colorsFromScryfall(Map<String, dynamic> json) {
  var colors = json['colors'] as List<dynamic>?;
  if (colors == null) {
    final faces = json['card_faces'] as List<dynamic>?;
    if (faces != null && faces.isNotEmpty) {
      colors = (faces.first as Map<String, dynamic>)['colors'] as List?;
    }
  }
  final present = (colors ?? []).map((e) => e.toString()).toSet();
  return _wubrg.where(present.contains).join();
}

/// Color identity in WUBRG order (includes mana symbols in rules text). Always
/// present at the top level on Scryfall cards, even for lands.
String colorIdentityFromScryfall(Map<String, dynamic> json) {
  final ci = json['color_identity'] as List<dynamic>?;
  final present = (ci ?? []).map((e) => e.toString()).toSet();
  return _wubrg.where(present.contains).join();
}

/// Converted mana cost / mana value.
double cmcFromScryfall(Map<String, dynamic> json) {
  final cmc = json['cmc'];
  if (cmc is num) return cmc.toDouble();
  return double.tryParse(cmc?.toString() ?? '') ?? 0;
}

/// Type line, e.g. "Legendary Creature — Elf Druid" (front face for DFCs).
String typeLineFromScryfall(Map<String, dynamic> json) {
  final t = json['type_line'] as String?;
  if (t != null && t.isNotEmpty) return t;
  final faces = json['card_faces'] as List<dynamic>?;
  if (faces != null && faces.isNotEmpty) {
    return (faces.first as Map<String, dynamic>)['type_line'] as String? ?? '';
  }
  return '';
}

String? imageUrlFromScryfall(Map<String, dynamic> json) {
  final images = json['image_uris'] as Map<String, dynamic>?;
  if (images != null) {
    return (images['normal'] ?? images['large'] ?? images['small']) as String?;
  }
  final faces = json['card_faces'] as List<dynamic>?;
  if (faces != null && faces.isNotEmpty) {
    final front = faces.first as Map<String, dynamic>;
    final faceImages = front['image_uris'] as Map<String, dynamic>?;
    if (faceImages != null) {
      return (faceImages['normal'] ??
          faceImages['large'] ??
          faceImages['small']) as String?;
    }
  }
  return null;
}

double? priceFromScryfall(Map<String, dynamic> json, bool foil) {
  final prices = json['prices'] as Map<String, dynamic>?;
  if (prices == null) return null;
  final key = foil ? 'usd_foil' : 'usd';
  final raw = prices[key] ?? prices['usd'] ?? prices['usd_foil'];
  if (raw == null) return null;
  return double.tryParse(raw.toString());
}

/// The card types used to group a decklist, in display order.
enum CardType {
  creature,
  planeswalker,
  land,
  instant,
  sorcery,
  artifact,
  enchantment,
  battle,
  other,
}

extension CardTypeLabel on CardType {
  String get label => switch (this) {
        CardType.creature => 'Creatures',
        CardType.planeswalker => 'Planeswalkers',
        CardType.land => 'Lands',
        CardType.instant => 'Instants',
        CardType.sorcery => 'Sorceries',
        CardType.artifact => 'Artifacts',
        CardType.enchantment => 'Enchantments',
        CardType.battle => 'Battles',
        CardType.other => 'Other',
      };
}

/// Derives the deck-grouping bucket from a [typeLine]. First match by priority
/// wins (a type line can list several types): Creature → Planeswalker → Land →
/// Instant → Sorcery → Artifact → Enchantment → Battle → Other. Land is ahead of
/// Artifact/Enchantment so "Artifact Land" groups under Lands while "Artifact
/// Creature" groups under Creatures.
CardType primaryType(String typeLine) {
  final t = typeLine.toLowerCase();
  if (t.contains('creature')) return CardType.creature;
  if (t.contains('planeswalker')) return CardType.planeswalker;
  if (t.contains('land')) return CardType.land;
  if (t.contains('instant')) return CardType.instant;
  if (t.contains('sorcery')) return CardType.sorcery;
  if (t.contains('artifact')) return CardType.artifact;
  if (t.contains('enchantment')) return CardType.enchantment;
  if (t.contains('battle')) return CardType.battle;
  return CardType.other;
}
