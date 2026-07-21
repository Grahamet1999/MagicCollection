import 'package:csv/csv.dart';

import '../models/deck_card.dart';

/// Builds CSV text for exporting a deck.
class DeckCsvExportService {
  /// A standard deck CSV that the app's own deck importer can read back: one row
  /// per card, tagged with its board (main/side/commander). Cards are emitted in
  /// commander → mainboard → sideboard order.
  static String standard(List<DeckCard> cards) {
    const order = {
      DeckBoard.commander: 0,
      DeckBoard.main: 1,
      DeckBoard.side: 2,
    };
    final sorted = [...cards]
      ..sort((a, b) {
        final byBoard =
            (order[a.board] ?? 3).compareTo(order[b.board] ?? 3);
        if (byBoard != 0) return byBoard;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final rows = <List<dynamic>>[
      [
        'Name',
        'Set',
        'Collector Number',
        'Foil',
        'Quantity',
        'Price USD',
        'Board',
      ],
      for (final c in sorted)
        [
          c.name,
          c.setCode,
          c.collectorNumber,
          c.foil ? 'true' : 'false',
          c.quantity,
          c.priceUsd ?? '',
          c.board,
        ],
    ];
    return const ListToCsvConverter().convert(rows);
  }
}
