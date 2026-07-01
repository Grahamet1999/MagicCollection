import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import '../models/mtg_card.dart';
import 'database_service.dart';
import 'scryfall_service.dart';

/// Imports cards from a CSV file, resolving each row against Scryfall and
/// storing the matched printings.
///
/// Headers are matched flexibly (case-insensitive, punctuation ignored). Each
/// row must identify a card either by **set code + collector number** (exact
/// printing) or by **name**. Optional columns: quantity, foil, folder.
class CsvImportService {
  CsvImportService(this._db, this._scryfall);

  final DatabaseService _db;
  final ScryfallService _scryfall;

  Future<CsvImportResult> importFromBytes(Uint8List bytes) async {
    final content = _decode(bytes);
    final table = const CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
    ).convert(content.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));

    if (table.isEmpty) {
      throw const FormatException('The CSV file is empty.');
    }

    final header = table.first.map((e) => _normalize(e.toString())).toList();
    final cols = _Columns(header);
    if (!cols.hasIdentity) {
      throw const FormatException(
        'CSV needs a "name" column, or both "set" and "collector number" '
        'columns, to identify cards.',
      );
    }

    // Parse data rows into pending imports.
    final rows = <_Row>[];
    var skipped = 0;
    for (final raw in table.skip(1)) {
      if (raw.every((c) => c.toString().trim().isEmpty)) continue; // blank line
      final row = _Row.fromCells(raw, cols);
      if (row == null) {
        skipped++;
      } else {
        rows.add(row);
      }
    }

    if (rows.isEmpty) {
      return CsvImportResult(imported: 0, notFound: const [], skipped: skipped);
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
    final notFound = <String>[];
    final folderCache = <String, int>{};

    for (final row in rows) {
      final card = row.bySet
          ? bySetNumber['${row.set!.toLowerCase()}|${row.number}']
          : byName[row.name!.toLowerCase()];

      if (card == null) {
        notFound.add(row.describe());
        continue;
      }

      int? folderId;
      if (row.folder != null && row.folder!.isNotEmpty) {
        folderId =
            folderCache[row.folder!] ??= await _db.getOrCreateFolder(row.folder!);
      }

      final mtgCard = MtgCard.fromScryfall(
        card,
        foil: row.foil,
        quantity: row.quantity,
      ).copyWith(folderId: folderId);
      // Merge into an existing matching printing if present; otherwise insert.
      await _db.addOrMergeCard(mtgCard);
      imported++;
    }

    return CsvImportResult(
      imported: imported,
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

  static String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Maps normalized header names to column indices, accepting common aliases.
class _Columns {
  _Columns(List<String> header) {
    name = _find(header, ['name', 'cardname', 'card']);
    set = _find(header, ['set', 'setcode', 'edition', 'editioncode', 'code']);
    number = _find(
      header,
      ['collectornumber', 'cardnumber', 'number', 'collectorno', 'cn'],
    );
    quantity = _find(header, ['quantity', 'qty', 'count', 'amount']);
    foil = _find(header, ['foil', 'finish', 'isfoil', 'printing', 'foiling']);
    folder = _find(header, ['folder', 'binder', 'category', 'list']);
  }

  late final int name;
  late final int set;
  late final int number;
  late final int quantity;
  late final int foil;
  late final int folder;

  bool get hasIdentity => name >= 0 || (set >= 0 && number >= 0);

  static int _find(List<String> header, List<String> aliases) {
    for (final alias in aliases) {
      final i = header.indexOf(alias);
      if (i >= 0) return i;
    }
    return -1;
  }
}

/// One parsed CSV data row ready to resolve and import.
class _Row {
  _Row({
    required this.quantity,
    required this.foil,
    this.set,
    this.number,
    this.name,
    this.folder,
  });

  final int quantity;
  final bool foil;
  final String? set;
  final String? number;
  final String? name;
  final String? folder;

  /// Prefer the exact printing (set + number) when both are present.
  bool get bySet =>
      (set?.isNotEmpty ?? false) && (number?.isNotEmpty ?? false);

  Map<String, String> get identifier => bySet
      ? {'set': set!.toLowerCase(), 'collector_number': number!}
      : {'name': name!};

  String describe() => bySet
      ? '${set!.toUpperCase()} #$number'
      : (name ?? '(unidentified row)');

  static _Row? fromCells(List<dynamic> cells, _Columns cols) {
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

    return _Row(
      quantity: _parseQuantity(at(cols.quantity)),
      foil: _parseFoil(at(cols.foil)),
      set: set,
      number: number,
      name: name,
      folder: at(cols.folder),
    );
  }

  static int _parseQuantity(String? v) {
    if (v == null) return 1;
    final n = int.tryParse(v.trim());
    return (n == null || n < 1) ? 1 : n;
  }

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
}

/// Summary of a CSV import for display to the user.
class CsvImportResult {
  CsvImportResult({
    required this.imported,
    required this.notFound,
    required this.skipped,
  });

  /// Number of cards successfully stored.
  final int imported;

  /// Human-readable descriptions of rows Scryfall couldn't match.
  final List<String> notFound;

  /// Rows ignored because they had no usable card identifier.
  final int skipped;
}
