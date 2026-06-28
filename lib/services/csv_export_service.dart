import 'package:csv/csv.dart';

import '../models/mtg_card.dart';

/// Builds CSV text for exporting the collection.
class CsvExportService {
  /// A standard CSV that the app's own importer can read back, including the
  /// folder each entry lives in. One row per stored entry (so a card split
  /// across folders produces one row per folder).
  static String standard(List<MtgCard> cards, Map<int, String> folderNames) {
    final rows = <List<dynamic>>[
      [
        'Name',
        'Set',
        'Collector Number',
        'Foil',
        'Quantity',
        'Price USD',
        'Colors',
        'Folder',
      ],
      for (final c in cards)
        [
          c.name,
          c.setCode,
          c.collectorNumber,
          c.foil ? 'true' : 'false',
          c.quantity,
          c.priceUsd ?? '',
          c.colors,
          c.folderId == null ? '' : (folderNames[c.folderId] ?? ''),
        ],
    ];
    return const ListToCsvConverter().convert(rows);
  }

  /// A Moxfield-compatible collection CSV. Moxfield has no folders, so entries
  /// are aggregated per printing (set + collector number + foil) and counts are
  /// summed across folders.
  static String moxfield(List<MtgCard> cards) {
    final rep = <String, MtgCard>{};
    final qty = <String, int>{};
    for (final c in cards) {
      final key = '${c.setCode}|${c.collectorNumber}|${c.foil}';
      rep[key] = c;
      qty[key] = (qty[key] ?? 0) + c.quantity;
    }

    final rows = <List<dynamic>>[
      [
        'Count',
        'Tradelist Count',
        'Name',
        'Edition',
        'Condition',
        'Language',
        'Foil',
        'Tags',
        'Last Modified',
        'Collector Number',
        'Alter',
        'Proxy',
        'Purchase Price',
      ],
      for (final entry in rep.entries)
        [
          qty[entry.key],
          0,
          entry.value.name,
          entry.value.setCode.toLowerCase(),
          'Near Mint',
          'English',
          entry.value.foil ? 'foil' : '',
          '',
          '',
          entry.value.collectorNumber,
          'False',
          'False',
          '',
        ],
    ];
    return const ListToCsvConverter().convert(rows);
  }
}
