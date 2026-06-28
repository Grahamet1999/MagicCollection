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
      folderId: folderId == _noChange ? this.folderId : folderId as int?,
    );
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
      imageUrl: _imageUrlFromScryfall(json),
      priceUsd: _priceFromScryfall(json, foil),
      colors: _colorsFromScryfall(json),
    );
  }

  static String _colorsFromScryfall(Map<String, dynamic> json) {
    var colors = json['colors'] as List<dynamic>?;
    if (colors == null) {
      // Double-faced cards keep colors under the front face.
      final faces = json['card_faces'] as List<dynamic>?;
      if (faces != null && faces.isNotEmpty) {
        colors = (faces.first as Map<String, dynamic>)['colors'] as List?;
      }
    }
    final present = (colors ?? []).map((e) => e.toString()).toSet();
    const order = ['W', 'U', 'B', 'R', 'G'];
    return order.where(present.contains).join();
  }

  static String? _imageUrlFromScryfall(Map<String, dynamic> json) {
    final images = json['image_uris'] as Map<String, dynamic>?;
    if (images != null) {
      return (images['normal'] ?? images['large'] ?? images['small'])
          as String?;
    }
    // Double-faced cards keep images under card_faces instead.
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

  static double? _priceFromScryfall(Map<String, dynamic> json, bool foil) {
    final prices = json['prices'] as Map<String, dynamic>?;
    if (prices == null) return null;
    final key = foil ? 'usd_foil' : 'usd';
    final raw = prices[key] ?? prices['usd'] ?? prices['usd_foil'];
    if (raw == null) return null;
    return double.tryParse(raw.toString());
  }
}

const Object _noChange = Object();
