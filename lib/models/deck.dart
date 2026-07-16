/// A user-created deck: a named card list independent of the collection.
class Deck {
  final int? id;
  final String name;

  /// Optional format label (e.g. "Commander", "Modern"). Informational only.
  final String? format;

  const Deck({this.id, required this.name, this.format});

  Deck copyWith({int? id, String? name, Object? format = _noChange}) {
    return Deck(
      id: id ?? this.id,
      name: name ?? this.name,
      format: format == _noChange ? this.format : format as String?,
    );
  }

  Map<String, Object?> toMap() => {'id': id, 'name': name, 'format': format};

  factory Deck.fromMap(Map<String, Object?> map) => Deck(
        id: map['id'] as int?,
        name: map['name'] as String,
        format: map['format'] as String?,
      );
}

const Object _noChange = Object();
