import '../models/mtg_card.dart';

/// A card published to a group binder, attributed to the member who owns it.
/// This is a snapshot of one of a member's collection cards, carried into the
/// shared cloud space so others can see who owns what (for trading).
class GroupCard {
  GroupCard({
    required this.ownerUid,
    required this.ownerName,
    required this.key,
    required this.name,
    required this.setCode,
    required this.collectorNumber,
    required this.foil,
    required this.quantity,
    required this.imageUrl,
    required this.priceUsd,
    required this.colors,
    required this.colorIdentity,
    required this.tags,
  });

  final String ownerUid;
  final String ownerName;

  /// Stable RTDB key for this card within the owner's subtree.
  final String key;

  final String name;
  final String setCode;
  final String collectorNumber;
  final bool foil;
  final int quantity;
  final String? imageUrl;
  final double? priceUsd;
  final String colors;
  final String colorIdentity;
  final List<String> tags;

  /// Builds the RTDB payload for a member's published card (owner attribution is
  /// implied by its path, so it isn't duplicated here).
  static Map<String, dynamic> toRtdb(MtgCard card) => {
        'name': card.name,
        'setCode': card.setCode,
        'collectorNumber': card.collectorNumber,
        'foil': card.foil,
        'quantity': card.quantity,
        'imageUrl': card.imageUrl,
        'priceUsd': card.priceUsd,
        'colors': card.colors,
        'colorIdentity': card.colorIdentity,
        'tags': card.tags,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      };

  factory GroupCard.fromRtdb({
    required String ownerUid,
    required String ownerName,
    required String key,
    required Map<String, dynamic> json,
  }) {
    return GroupCard(
      ownerUid: ownerUid,
      ownerName: ownerName,
      key: key,
      name: json['name'] as String? ?? 'Unknown',
      setCode: json['setCode'] as String? ?? '',
      collectorNumber: json['collectorNumber'] as String? ?? '',
      foil: json['foil'] as bool? ?? false,
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      imageUrl: json['imageUrl'] as String?,
      priceUsd: (json['priceUsd'] as num?)?.toDouble(),
      colors: json['colors'] as String? ?? '',
      colorIdentity: json['colorIdentity'] as String? ?? '',
      tags: ((json['tags'] as List<dynamic>?) ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// A stable card key derived from the printing + foil, so re-publishing
  /// updates the same node instead of duplicating.
  static String cardKey(MtgCard c) =>
      '${c.setCode}_${c.collectorNumber}_${c.foil ? 'f' : 'n'}'
          .replaceAll(RegExp(r'[.#$\[\]/]'), '-');
}
