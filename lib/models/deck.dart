/// A user-created deck: a named card list independent of the collection.
class Deck {
  /// SQLite primary key. Null until the deck row has been inserted.
  final int? id;

  /// User-visible deck name.
  final String name;

  /// Optional format label (e.g. "Commander", "Modern"). Informational only.
  final String? format;

  const Deck({this.id, required this.name, this.format});

  /// Returns a copy with the given fields replaced.
  ///
  /// [format] uses the [_noChange] sentinel so callers can distinguish "leave
  /// the format as-is" (omit the argument) from "clear the format" (pass null).
  Deck copyWith({int? id, String? name, Object? format = _noChange}) {
    return Deck(
      id: id ?? this.id,
      name: name ?? this.name,
      format: format == _noChange ? this.format : format as String?,
    );
  }

  /// Serializes to a row map for the `decks` table.
  Map<String, Object?> toMap() => {'id': id, 'name': name, 'format': format};

  /// Rebuilds a [Deck] from a `decks` table row.
  factory Deck.fromMap(Map<String, Object?> map) => Deck(
        id: map['id'] as int?,
        name: map['name'] as String,
        format: map['format'] as String?,
      );
}

/// Sentinel default for [Deck.copyWith]'s nullable [format], letting the method
/// tell "argument omitted" apart from "explicitly set to null".
const Object _noChange = Object();
