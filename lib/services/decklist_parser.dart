/// One card line parsed from a pasted decklist: a card name and a quantity.
class ParsedCardLine {
  const ParsedCardLine({required this.name, required this.quantity});

  final String name;
  final int quantity;
}

/// Parses a free-text decklist (the format people paste from Moxfield,
/// Archidekt, MTGGoldfish, or type by hand) into card names + quantities.
///
/// Handles the common shapes: `1 Sol Ring`, `1x Sol Ring`, `10 Forest`, bare
/// `Sol Ring`, trailing set/collector/foil annotations (`Sol Ring (C21) 263 *F*`),
/// `//` and `#` comments, `SB:` sideboard markers, and section headers
/// (`Commander:`, `Creatures (10)`). Same-named lines are merged, summing
/// quantities. This is deliberately lenient — unresolved names are caught later
/// when the list is looked up against Scryfall.
class DecklistParser {
  const DecklistParser._();

  static final _qtyPrefix = RegExp(r'^(\d+)\s*[xX]?\s+(.+)$');
  static final _foilSuffix = RegExp(r'\s*\*[a-zA-Z]\*\s*$');
  static final _setSuffix = RegExp(r'\s*\([^)]*\)\s*[0-9A-Za-z-]*\s*$');
  static final _sideboardPrefix = RegExp(r'^sb:\s*', caseSensitive: false);

  /// Section-header words to ignore when they appear on a line of their own.
  static const _headerWords = {
    'deck',
    'sideboard',
    'maybeboard',
    'commander',
    'commanders',
    'companion',
  };

  static List<ParsedCardLine> parse(String text) {
    final qty = <String, int>{}; // lowercased name → total quantity
    final display = <String, String>{}; // lowercased name → original casing

    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('//') || line.startsWith('#')) continue;
      line = line.replaceFirst(_sideboardPrefix, '');
      if (line.endsWith(':')) continue; // "Commander:", "Lands:" …

      var count = 1;
      String name;
      final m = _qtyPrefix.firstMatch(line);
      if (m != null) {
        count = int.tryParse(m.group(1)!) ?? 1;
        name = m.group(2)!.trim();
      } else {
        name = line;
      }

      // Strip trailing foil marker then set/collector annotation.
      name = name.replaceFirst(_foilSuffix, '');
      name = name.replaceFirst(_setSuffix, '').trim();
      if (name.isEmpty) continue;

      final key = name.toLowerCase();
      if (_headerWords.contains(key)) continue;
      if (count < 1) count = 1;

      qty[key] = (qty[key] ?? 0) + count;
      display.putIfAbsent(key, () => name);
    }

    return [
      for (final e in qty.entries)
        ParsedCardLine(name: display[e.key]!, quantity: e.value),
    ];
  }
}
