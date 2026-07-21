import 'dart:convert';

import 'scryfall_parse.dart' as sf;

/// A single Magic: The Gathering card stored in the local collection.
///
/// A card always belongs to the overall collection. It may optionally live in
/// exactly one [folder] via [folderId]; a null [folderId] means "no folder"
/// (still in the collection, just unfiled).
class MtgCard {
  /// SQLite primary key. Null until the row has been inserted.
  final int? id;

  /// Card name.
  final String name;

  /// Set code, e.g. "NEO".
  final String setCode;

  /// Collector number within the set.
  final String collectorNumber;

  /// Whether this is the foil printing.
  final bool foil;

  /// Number of copies owned.
  final int quantity;

  /// Scryfall image URL, if known.
  final String? imageUrl;

  /// Latest USD price snapshot, if known.
  final double? priceUsd;

  /// The folder this card is filed under, or null for "no folder" (see the
  /// class doc). Cleared via [copyWith] using the [_noChange] sentinel.
  final int? folderId;

  /// Card colors in WUBRG order, e.g. "W", "WU", or "" for colorless.
  final String colors;

  /// Color identity in WUBRG order (includes mana symbols in rules text), used
  /// for commander color-identity filtering. "" = colorless.
  final String colorIdentity;

  /// Free-form trade tags, e.g. ["Trade", "Want", "Keep"].
  final List<String> tags;

  /// Full type line, e.g. "Legendary Creature — Elf Druid". Backfilled from
  /// Scryfall to power the advanced type/subtype search; "" = not yet known.
  final String typeLine;

  /// Converted mana cost / mana value, backfilled from Scryfall for the advanced
  /// mana-value filter. Null = not yet known.
  final double? cmc;

  /// Oracle rules text, backfilled from Scryfall for the advanced rules-text
  /// search; "" = not yet known (or genuinely no text).
  final String oracleText;

  const MtgCard({
    this.id,
    required this.name,
    required this.setCode,
    required this.collectorNumber,
    this.foil = false,
    this.quantity = 1,
    this.imageUrl,
    this.priceUsd,
    this.folderId,
    this.colors = '',
    this.colorIdentity = '',
    this.tags = const [],
    this.typeLine = '',
    this.cmc,
    this.oracleText = '',
  });

  MtgCard copyWith({
    int? id,
    String? name,
    String? setCode,
    String? collectorNumber,
    bool? foil,
    int? quantity,
    String? imageUrl,
    double? priceUsd,
    String? colors,
    String? colorIdentity,
    List<String>? tags,
    String? typeLine,
    double? cmc,
    String? oracleText,
    // Use a sentinel so callers can explicitly clear the folder (set to null).
    Object? folderId = _noChange,
  }) {
    return MtgCard(
      id: id ?? this.id,
      name: name ?? this.name,
      setCode: setCode ?? this.setCode,
      collectorNumber: collectorNumber ?? this.collectorNumber,
      foil: foil ?? this.foil,
      quantity: quantity ?? this.quantity,
      imageUrl: imageUrl ?? this.imageUrl,
      priceUsd: priceUsd ?? this.priceUsd,
      colors: colors ?? this.colors,
      colorIdentity: colorIdentity ?? this.colorIdentity,
      tags: tags ?? this.tags,
      typeLine: typeLine ?? this.typeLine,
      cmc: cmc ?? this.cmc,
      oracleText: oracleText ?? this.oracleText,
      folderId: folderId == _noChange ? this.folderId : folderId as int?,
    );
  }

  /// Encodes [tags] to a JSON string for storage; decodes with [decodeTags].
  static String encodeTags(List<String> tags) => jsonEncode(tags);

  static List<String> decodeTags(Object? raw) {
    if (raw == null) return const [];
    final s = raw.toString();
    if (s.isEmpty) return const [];
    try {
      final decoded = jsonDecode(s);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // Fall back to treating a bare string as a single tag.
      return [s];
    }
    return const [];
  }

  /// Sort rank for color: W, U, B, R, G, then multicolor, then colorless.
  static int colorRank(String colors) {
    if (colors.isEmpty) return 7; // colorless
    if (colors.length > 1) return 6; // multicolor
    switch (colors) {
      case 'W':
        return 1;
      case 'U':
        return 2;
      case 'B':
        return 3;
      case 'R':
        return 4;
      case 'G':
        return 5;
      default:
        return 8;
    }
  }

  /// Serializes to a row map for the `cards` table. [foil] is stored as 0/1 and
  /// [tags] as a JSON string (see [encodeTags]) to fit relational columns.
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'set_code': setCode,
      'collector_number': collectorNumber,
      'foil': foil ? 1 : 0,
      'quantity': quantity,
      'image_url': imageUrl,
      'price_usd': priceUsd,
      'folder_id': folderId,
      'colors': colors,
      'color_identity': colorIdentity,
      'tags': encodeTags(tags),
      'type_line': typeLine,
      'cmc': cmc,
      'oracle_text': oracleText,
    };
  }

  /// Rebuilds an [MtgCard] from a `cards` table row.
  factory MtgCard.fromMap(Map<String, Object?> map) {
    return MtgCard(
      id: map['id'] as int?,
      name: map['name'] as String,
      setCode: map['set_code'] as String,
      collectorNumber: map['collector_number'] as String,
      foil: (map['foil'] as int? ?? 0) == 1,
      quantity: map['quantity'] as int? ?? 1,
      imageUrl: map['image_url'] as String?,
      priceUsd: (map['price_usd'] as num?)?.toDouble(),
      folderId: map['folder_id'] as int?,
      colors: map['colors'] as String? ?? '',
      colorIdentity: map['color_identity'] as String? ?? '',
      tags: decodeTags(map['tags']),
      typeLine: map['type_line'] as String? ?? '',
      cmc: (map['cmc'] as num?)?.toDouble(),
      oracleText: map['oracle_text'] as String? ?? '',
    );
  }

  /// Builds a card from a Scryfall card JSON object (e.g. from
  /// `/cards/:set/:number` or a `/cards/search` result entry).
  factory MtgCard.fromScryfall(
    Map<String, dynamic> json, {
    bool foil = false,
    int quantity = 1,
  }) {
    return MtgCard(
      name: json['name'] as String? ?? 'Unknown',
      setCode: (json['set'] as String? ?? '').toUpperCase(),
      collectorNumber: json['collector_number'] as String? ?? '',
      foil: foil,
      quantity: quantity,
      imageUrl: sf.imageUrlFromScryfall(json),
      priceUsd: sf.priceFromScryfall(json, foil),
      colors: sf.colorsFromScryfall(json),
      colorIdentity: sf.colorIdentityFromScryfall(json),
      typeLine: sf.typeLineFromScryfall(json),
      cmc: sf.cmcFromScryfall(json),
      oracleText: sf.oracleTextFromScryfall(json),
    );
  }
}

const Object _noChange = Object();
