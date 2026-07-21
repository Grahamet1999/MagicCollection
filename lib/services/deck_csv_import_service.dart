import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import '../models/deck_card.dart';
import 'database_service.dart';
import 'scryfall_service.dart';

/// Imports cards from a CSV file into a single deck, resolving each row against
/// Scryfall and storing the matched printings on the requested board.
///
/// Headers are matched flexibly (case-insensitive, punctuation ignored). Each
/// row must identify a card either by **set code + collector number** (exact
/// printing) or by **name**. Optional columns: quantity, foil, board
/// (main/side/commander — defaults to mainboard).
class DeckCsvImportService {
  DeckCsvImportService(this._db, this._scryfall);

  final DatabaseService _db;
  final ScryfallService _scryfall;

  /// Parses the CSV in [bytes], resolves every row against Scryfall in batches,
  /// and adds the matched printings to the deck with [deckId] (merging into
  /// matching entries). Returns a [DeckCsvImportResult] summarizing the outcome.
  Future<DeckCsvImportResult> importFromBytes(
    Uint8List bytes, {
    required int deckId,
  }) async {
    final content = _decode(bytes);
    final table = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
    ).convert(content.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));

    if (table.isEmpty) {
      throw const FormatException('The CSV file is empty.');
    }

    final header = table.first.map((e) => _normalize(e.toString())).toList();
    final cols = _DeckColumns(header);
    if (!cols.hasIdentity) {
      throw const FormatException(
        'CSV needs a "name" column, or both "set" and "collector number" '
        'columns, to identify cards.',
      );
    }

    // Parse data rows into pending imports.
    final rows = <_DeckRow>[];
    var skipped = 0;
    for (final raw in table.skip(1)) {
      if (raw.every((c) => c.toString().trim().isEmpty)) continue; // blank line
      final row = _DeckRow.fromCells(raw, cols);
      if (row == null) {
        skipped++;
      } else {
        rows.add(row);
      }
    }

    if (rows.isEmpty) {
      return DeckCsvImportResult(
        imported: 0,
        copies: 0,
        notFound: const [],
        skipped: skipped,
      );
    }

    // Batch-resolve via Scryfall and index results so either identifier style
    // can find its card.
    final result = await _scryfall.getCollection(
      rows.map((r) => r.identifier).toList(),
    );
    final bySetNumber = <String, Map<String, dynamic>>{};
    final byName = <String, Map<String, dynamic>>{};
    for (final card in result.found) {
      final set = (card['set'] as String? ?? '').toLowerCase();
      final number = card['collector_number'] as String? ?? '';
      bySetNumber['$set|$number'] = card;
      final name = (card['name'] as String? ?? '').toLowerCase();
      if (name.isNotEmpty) byName[name] = card;
    }

    var imported = 0;
    var copies = 0;
    final notFound = <String>[];

    for (final row in rows) {
      final card = row.bySet
          ? bySetNumber['${row.set!.toLowerCase()}|${row.number}']
          : byName[row.name!.toLowerCase()];

      if (card == null) {
        notFound.add(row.describe());
        continue;
      }

      final deckCard = DeckCard.fromScryfall(
        card,
        deckId: deckId,
        foil: row.foil,
        quantity: row.quantity,
        board: row.board,
      );
      // Merge into an existing matching printing on the same board if present.
      await _db.addOrMergeDeckCard(deckCard);
      imported++;
      copies += row.quantity;
    }

    return DeckCsvImportResult(
      imported: imported,
      copies: copies,
      notFound: notFound,
      skipped: skipped,
    );
  }

  /// Decodes bytes as UTF-8, stripping a BOM if present.
  String _decode(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3));
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Lowercases and strips non-alphanumerics so header/alias matching ignores
  /// case, spaces, and punctuation (e.g. "Collector #" → "collector").
  static String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Maps normalized header names to column indices, accepting common aliases.
class _DeckColumns {
  _DeckColumns(List<String> header) {
    name = _find(header, ['name', 'cardname', 'card']);
    set = _find(header, ['set', 'setcode', 'edition', 'editioncode', 'code']);
    number = _find(
      header,
      ['collectornumber', 'cardnumber', 'number', 'collectorno', 'cn'],
    );
    quantity = _find(header, ['quantity', 'qty', 'count', 'amount']);
    foil = _find(header, ['foil', 'finish', 'isfoil', 'printing', 'foiling']);
    board = _find(header, ['board', 'section', 'zone', 'category', 'list']);
  }

  late final int name;
  late final int set;
  late final int number;
  late final int quantity;
  late final int foil;
  late final int board;

  /// True if rows can be identified — by a name column, or by both set and
  /// collector-number columns.
  bool get hasIdentity => name >= 0 || (set >= 0 && number >= 0);

  /// Returns the index of the first [aliases] entry present in [header], or -1.
  static int _find(List<String> header, List<String> aliases) {
    for (final alias in aliases) {
      final i = header.indexOf(alias);
      if (i >= 0) return i;
    }
    return -1;
  }
}

/// One parsed CSV data row ready to resolve and import into a deck.
class _DeckRow {
  _DeckRow({
    required this.quantity,
    required this.foil,
    required this.board,
    this.set,
    this.number,
    this.name,
  });

  final int quantity;
  final bool foil;
  final String board;
  final String? set;
  final String? number;
  final String? name;

  /// Prefer the exact printing (set + number) when both are present.
  bool get bySet =>
      (set?.isNotEmpty ?? false) && (number?.isNotEmpty ?? false);

  /// The Scryfall `/cards/collection` identifier map for this row.
  Map<String, String> get identifier => bySet
      ? {'set': set!.toLowerCase(), 'collector_number': number!}
      : {'name': name!};

  /// A short human-readable label for this row, used in the not-found list.
  String describe() => bySet
      ? '${set!.toUpperCase()} #$number'
      : (name ?? '(unidentified row)');

  /// Builds a [_DeckRow] from raw [cells], or null if the row has no usable
  /// identifier (neither a name nor a set+number pair).
  static _DeckRow? fromCells(List<dynamic> cells, _DeckColumns cols) {
    String? at(int i) {
      if (i < 0 || i >= cells.length) return null;
      final v = cells[i].toString().trim();
      return v.isEmpty ? null : v;
    }

    final set = at(cols.set);
    final rawNumber = at(cols.number);
    // Normalize leading zeros so "001" matches Scryfall's canonical "1".
    final number = rawNumber == null
        ? null
        : ScryfallService.normalizeCollectorNumber(rawNumber);
    final name = at(cols.name);

    final hasSetNumber =
        (set?.isNotEmpty ?? false) && (number?.isNotEmpty ?? false);
    if (!hasSetNumber && (name == null || name.isEmpty)) {
      return null; // No usable identifier on this row.
    }

    return _DeckRow(
      quantity: _parseQuantity(at(cols.quantity)),
      foil: _parseFoil(at(cols.foil)),
      board: _parseBoard(at(cols.board)),
      set: set,
      number: number,
      name: name,
    );
  }

  /// Parses a quantity cell, defaulting to 1 for missing/invalid/&lt;1 values.
  static int _parseQuantity(String? v) {
    if (v == null) return 1;
    final n = int.tryParse(v.trim());
    return (n == null || n < 1) ? 1 : n;
  }

  /// Interprets a foil cell, treating foil/etched/yes/true/1/y as foil.
  static bool _parseFoil(String? v) {
    if (v == null) return false;
    final s = v.trim().toLowerCase();
    return s == 'foil' ||
        s == 'etched' ||
        s == 'yes' ||
        s == 'true' ||
        s == '1' ||
        s == 'y';
  }

  /// Maps a board cell to a [DeckBoard] value, defaulting to the mainboard.
  static String _parseBoard(String? v) {
    final s = v?.trim().toLowerCase() ?? '';
    if (s.startsWith('side') || s == 'sb') return DeckBoard.side;
    if (s.startsWith('command') || s == 'cmd') return DeckBoard.commander;
    return DeckBoard.main;
  }
}

/// Summary of a deck CSV import for display to the user.
class DeckCsvImportResult {
  DeckCsvImportResult({
    required this.imported,
    required this.copies,
    required this.notFound,
    required this.skipped,
  });

  /// Number of CSV rows (entries) successfully added to the deck.
  final int imported;

  /// Total copies added, summing each added row's quantity.
  final int copies;

  /// Human-readable descriptions of rows Scryfall couldn't match.
  final List<String> notFound;

  /// Rows ignored because they had no usable card identifier.
  final int skipped;
}
