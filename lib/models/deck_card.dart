import 'scryfall_parse.dart' as sf;

/// Board a deck card belongs to.
class DeckBoard {
  static const String commander = 'commander';
  static const String main = 'main';
  static const String side = 'side';
}

/// A card in a deck. Stores a full printing snapshot so decks are independent of
/// the collection (adding to a deck never touches collection quantities), plus
/// the fields needed for grouping, the mana curve, and the commander filter.
class DeckCard {
  /// SQLite primary key. Null until the row has been inserted.
  final int? id;

  /// Foreign key to the owning [Deck].
  final int deckId;

  /// Card name.
  final String name;

  /// Set code, e.g. "NEO".
  final String setCode;

  /// Collector number within the set.
  final String collectorNumber;

  /// Whether this is the foil printing.
  final bool foil;

  /// Number of copies of this card on this board.
  final int quantity;

  /// Scryfall image URL, if known.
  final String? imageUrl;

  /// USD price snapshot for the printing, if known.
  final double? priceUsd;

  /// Colors in WUBRG order ("" = colorless).
  final String colors;

  /// Color identity in WUBRG order, used by the commander color-identity filter.
  final String colorIdentity;

  /// Converted mana cost / mana value, used to build the mana curve.
  final double cmc;

  /// Full type line, e.g. "Legendary Creature — Elf Druid", used for grouping.
  final String typeLine;

  /// One of [DeckBoard.commander] / [DeckBoard.main] / [DeckBoard.side].
  final String board;

  const DeckCard({
    this.id,
    required this.deckId,
    required this.name,
    required this.setCode,
    required this.collectorNumber,
    this.foil = false,
    this.quantity = 1,
    this.imageUrl,
    this.priceUsd,
    this.colors = '',
    this.colorIdentity = '',
    this.cmc = 0,
    this.typeLine = '',
    this.board = DeckBoard.main,
  });

  /// The grouping bucket (Creatures, Lands, …) derived from [typeLine].
  sf.CardType get primaryType => sf.primaryType(typeLine);

  /// Returns a copy with the given fields replaced (all optional).
  DeckCard copyWith({
    int? id,
    int? deckId,
    String? name,
    String? setCode,
    String? collectorNumber,
    bool? foil,
    int? quantity,
    String? imageUrl,
    double? priceUsd,
    String? colors,
    String? colorIdentity,
    double? cmc,
    String? typeLine,
    String? board,
  }) {
    return DeckCard(
      id: id ?? this.id,
      deckId: deckId ?? this.deckId,
      name: name ?? this.name,
      setCode: setCode ?? this.setCode,
      collectorNumber: collectorNumber ?? this.collectorNumber,
      foil: foil ?? this.foil,
      quantity: quantity ?? this.quantity,
      imageUrl: imageUrl ?? this.imageUrl,
      priceUsd: priceUsd ?? this.priceUsd,
      colors: colors ?? this.colors,
      colorIdentity: colorIdentity ?? this.colorIdentity,
      cmc: cmc ?? this.cmc,
      typeLine: typeLine ?? this.typeLine,
      board: board ?? this.board,
    );
  }

  /// Serializes to a row map for the `deck_cards` table. Booleans are stored as
  /// 0/1 integers to match SQLite's type affinity.
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'deck_id': deckId,
      'name': name,
      'set_code': setCode,
      'collector_number': collectorNumber,
      'foil': foil ? 1 : 0,
      'quantity': quantity,
      'image_url': imageUrl,
      'price_usd': priceUsd,
      'colors': colors,
      'color_identity': colorIdentity,
      'cmc': cmc,
      'type_line': typeLine,
      'board': board,
    };
  }

  /// Rebuilds a [DeckCard] from a `deck_cards` table row.
  factory DeckCard.fromMap(Map<String, Object?> map) {
    return DeckCard(
      id: map['id'] as int?,
      deckId: map['deck_id'] as int,
      name: map['name'] as String,
      setCode: map['set_code'] as String,
      collectorNumber: map['collector_number'] as String,
      foil: (map['foil'] as int? ?? 0) == 1,
      quantity: map['quantity'] as int? ?? 1,
      imageUrl: map['image_url'] as String?,
      priceUsd: (map['price_usd'] as num?)?.toDouble(),
      colors: map['colors'] as String? ?? '',
      colorIdentity: map['color_identity'] as String? ?? '',
      cmc: (map['cmc'] as num?)?.toDouble() ?? 0,
      typeLine: map['type_line'] as String? ?? '',
      board: map['board'] as String? ?? DeckBoard.main,
    );
  }

  /// Builds a deck card from Scryfall JSON for [deckId] on [board].
  factory DeckCard.fromScryfall(
    Map<String, dynamic> json, {
    required int deckId,
    bool foil = false,
    int quantity = 1,
    String board = DeckBoard.main,
  }) {
    return DeckCard(
      deckId: deckId,
      name: json['name'] as String? ?? 'Unknown',
      setCode: (json['set'] as String? ?? '').toUpperCase(),
      collectorNumber: json['collector_number'] as String? ?? '',
      foil: foil,
      quantity: quantity,
      imageUrl: sf.imageUrlFromScryfall(json),
      priceUsd: sf.priceFromScryfall(json, foil),
      colors: sf.colorsFromScryfall(json),
      colorIdentity: sf.colorIdentityFromScryfall(json),
      cmc: sf.cmcFromScryfall(json),
      typeLine: sf.typeLineFromScryfall(json),
      board: board,
    );
  }
}
