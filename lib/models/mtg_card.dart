import 'dart:convert';

import 'scryfall_parse.dart' as sf;

/// A single Magic: The Gathering card stored in the local collection.
///
/// A card always belongs to the overall collection. It may optionally live in
/// exactly one [folder] via [folderId]; a null [folderId] means "no folder"
/// (still in the collection, just unfiled).
class MtgCard {
  final int? id;
  final String name;
  final String setCode;
  final String collectorNumber;
  final bool foil;
  final int quantity;
  final String? imageUrl;
  final double? priceUsd;
  final int? folderId;

  /// Card colors in WUBRG order, e.g. "W", "WU", or "" for colorless.
  final String colors;

  /// Color identity in WUBRG order (includes mana symbols in rules text), used
  /// for commander color-identity filtering. "" = colorless.
  final String colorIdentity;

  /// Free-form trade tags, e.g. ["Trade", "Want", "Keep"].
  final List<String> tags;

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
    };
  }

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
    );
  }
}

const Object _noChange = Object();
