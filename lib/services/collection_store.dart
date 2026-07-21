import 'package:flutter/foundation.dart';

import '../models/folder.dart';
import '../models/mtg_card.dart';
import 'database_service.dart';
import 'scryfall_service.dart';

/// In-memory coordinator over [DatabaseService] shared by both tabs.
///
/// Holds the current folder list and the filtered card view, and notifies
/// listeners so the Import and Collection tabs stay in sync (importing a card
/// refreshes the collection automatically).
class CollectionStore extends ChangeNotifier {
  CollectionStore(this._db);

  final DatabaseService _db;

  List<Folder> _folders = [];
  List<MtgCard> _cards = [];
  List<AggregatedCard> _aggregated = [];
  Map<int, int> _folderCounts = {};

  String _query = '';
  // null = All cards; unfiledSentinel = Unfiled; otherwise a folder id.
  int? _selectedFolderId;
  CardSort _sort = CardSort.name;
  bool _sortAscending = true;
  Set<String> _selectedTags = {};

  // Advanced search filters, applied in-memory after the DB query.
  List<String> _allSets = [];
  String _setFilter = ''; // exact set code; '' = any set
  String _typeQuery = ''; // substring on type_line
  String _textQuery = ''; // substring on oracle_text
  int? _cmcMin;
  int? _cmcMax;
  // Color tokens: 'W','U','B','R','G', plus 'C' (colorless) and 'M' (multicolor).
  Set<String> _colorFilter = {};

  // Read-only views of the current state for the UI to render.
  List<Folder> get folders => _folders;
  List<MtgCard> get cards => _cards;

  /// Cards combined per printing (set + number + foil) across folders. Only
  /// meaningful in the "All cards" view ([isAggregated]).
  List<AggregatedCard> get aggregatedCards => _aggregated;

  /// True for the "All cards" view, where entries split across folders are
  /// collapsed into one tile showing the combined total.
  bool get isAggregated => _selectedFolderId == null;

  Map<int, int> get folderCounts => _folderCounts;
  String get query => _query;
  int? get selectedFolderId => _selectedFolderId;
  CardSort get sort => _sort;
  bool get sortAscending => _sortAscending;
  Set<String> get selectedTags => _selectedTags;

  // Advanced filter state, surfaced for the advanced-search panel.
  List<String> get availableSets => _allSets;
  String get setFilter => _setFilter;
  String get typeQuery => _typeQuery;
  String get textQuery => _textQuery;
  int? get cmcMin => _cmcMin;
  int? get cmcMax => _cmcMax;
  Set<String> get colorFilter => _colorFilter;

  /// True when any advanced filter is active (used to badge the toggle).
  bool get hasAdvancedFilters =>
      _setFilter.isNotEmpty ||
      _typeQuery.trim().isNotEmpty ||
      _textQuery.trim().isNotEmpty ||
      _cmcMin != null ||
      _cmcMax != null ||
      _colorFilter.isNotEmpty;
  int get totalCards => _cards.fold(0, (sum, c) => sum + c.quantity);

  /// Total USD value of the current view (sum of price × quantity), summed over
  /// the displayed folder / Unfiled / All cards.
  double get totalValue =>
      _cards.fold(0.0, (sum, c) => sum + (c.priceUsd ?? 0) * c.quantity);

  /// Reloads folders, counts, and the filtered/sorted card list from the
  /// database using the current query/folder/sort/tag filters, then notifies
  /// listeners. Every mutator below ends by calling this.
  Future<void> load() async {
    _folders = await _db.getFolders();
    _folderCounts = await _db.folderCardCounts();
    _allSets = await _db.distinctSetCodes();
    var cards = await _db.getCards(
      query: _query,
      folderId: _selectedFolderId,
      sort: _sort,
      ascending: _sortAscending,
    );
    if (_selectedTags.isNotEmpty) {
      cards = cards.where((c) => c.tags.any(_selectedTags.contains)).toList();
    }
    cards = _applyAdvancedFilters(cards);
    _cards = cards;
    _aggregated = isAggregated ? _aggregate(_cards) : const [];
    notifyListeners();
  }

  /// Applies the in-memory advanced filters (set, type, rules text, mana value,
  /// color) to [cards]. Cards missing backfilled detail fields are excluded when
  /// a filter that needs them is active.
  List<MtgCard> _applyAdvancedFilters(List<MtgCard> cards) {
    var out = cards;
    if (_setFilter.isNotEmpty) {
      final s = _setFilter.toLowerCase();
      out = out.where((c) => c.setCode.toLowerCase() == s).toList();
    }
    if (_typeQuery.trim().isNotEmpty) {
      final q = _typeQuery.trim().toLowerCase();
      out = out.where((c) => c.typeLine.toLowerCase().contains(q)).toList();
    }
    if (_textQuery.trim().isNotEmpty) {
      final q = _textQuery.trim().toLowerCase();
      out = out.where((c) => c.oracleText.toLowerCase().contains(q)).toList();
    }
    if (_cmcMin != null) {
      out = out.where((c) => c.cmc != null && c.cmc! >= _cmcMin!).toList();
    }
    if (_cmcMax != null) {
      out = out.where((c) => c.cmc != null && c.cmc! <= _cmcMax!).toList();
    }
    if (_colorFilter.isNotEmpty) {
      out = out.where((c) => _matchesColor(c.colors)).toList();
    }
    return out;
  }

  /// True when [colors] matches any selected color token (mono letters, plus
  /// 'C' for colorless and 'M' for multicolor).
  bool _matchesColor(String colors) {
    for (final token in _colorFilter) {
      if (token == 'C' && colors.isEmpty) return true;
      if (token == 'M' && colors.length > 1) return true;
      if (token.length == 1 &&
          'WUBRG'.contains(token) &&
          colors.contains(token)) {
        return true;
      }
    }
    return false;
  }

  /// Restricts the view to cards carrying any of [tags] ("" set = no filter).
  Future<void> setTagFilter(Set<String> tags) async {
    _selectedTags = tags;
    await load();
  }

  /// Sets the exact set-code filter ("" = any) and reloads.
  Future<void> setSetFilter(String setCode) async {
    _setFilter = setCode;
    await load();
  }

  /// Sets the type/subtype substring filter and reloads.
  Future<void> setTypeQuery(String value) async {
    _typeQuery = value;
    await load();
  }

  /// Sets the rules-text (oracle) substring filter and reloads.
  Future<void> setTextQuery(String value) async {
    _textQuery = value;
    await load();
  }

  /// Sets the inclusive mana-value bounds (null = unbounded) and reloads.
  Future<void> setCmcRange(int? min, int? max) async {
    _cmcMin = min;
    _cmcMax = max;
    await load();
  }

  /// Sets the color token filter and reloads.
  Future<void> setColorFilter(Set<String> colors) async {
    _colorFilter = colors;
    await load();
  }

  /// Clears every advanced filter and reloads.
  Future<void> clearAdvancedFilters() async {
    _setFilter = '';
    _typeQuery = '';
    _textQuery = '';
    _cmcMin = null;
    _cmcMax = null;
    _colorFilter = {};
    await load();
  }

  /// Backfills type line / mana value / oracle text from Scryfall for any cards
  /// missing them (identified by an empty type line), so the advanced type,
  /// mana-value, and rules-text filters work on the existing collection. Returns
  /// how many entries were updated out of how many needed it.
  Future<DetailBackfillResult> backfillCardDetails({
    void Function(int done, int total)? onProgress,
  }) async {
    final all = await _db.getCards();
    final missing = all.where((c) => c.typeLine.isEmpty).toList();
    if (missing.isEmpty) return const DetailBackfillResult(updated: 0, total: 0);

    // One lookup per unique printing (progress is reported over these).
    final byKey = <String, Map<String, String>>{};
    for (final c in missing) {
      byKey['${c.setCode.toLowerCase()}|${c.collectorNumber}'] = {
        'set': c.setCode.toLowerCase(),
        'collector_number': c.collectorNumber,
      };
    }
    final identifiers = byKey.values.toList();
    final total = identifiers.length;
    onProgress?.call(0, total);

    final scryfall = ScryfallService();
    try {
      // Resolve in chunks so progress advances as each batch returns.
      final jsonByKey = <String, Map<String, dynamic>>{};
      const chunkSize = 75;
      for (var i = 0; i < identifiers.length; i += chunkSize) {
        final end = (i + chunkSize < identifiers.length)
            ? i + chunkSize
            : identifiers.length;
        final result =
            await scryfall.getCollection(identifiers.sublist(i, end));
        for (final j in result.found) {
          jsonByKey['${(j['set'] as String).toLowerCase()}'
              '|${j['collector_number']}'] = j;
        }
        onProgress?.call(end, total);
      }

      var updated = 0;
      for (final c in missing) {
        final json =
            jsonByKey['${c.setCode.toLowerCase()}|${c.collectorNumber}'];
        if (json == null) continue;
        final e = MtgCard.fromScryfall(json, foil: c.foil);
        await _db.setCardDetails(
          c.id!,
          typeLine: e.typeLine,
          cmc: e.cmc,
          oracleText: e.oracleText,
        );
        updated++;
      }
      await load();
      return DetailBackfillResult(updated: updated, total: missing.length);
    } finally {
      scryfall.dispose();
    }
  }

  /// Sets the trade tags on a card (leaves the rest of the entry untouched).
  Future<void> setTags(MtgCard card, List<String> tags) async {
    await _db.setCardTags(card.id!, tags);
    await load();
  }

  /// Collapses entries sharing a printing (set + number + foil) into one
  /// [AggregatedCard] per printing, recording each folder location and the
  /// combined total. Used only in the "All cards" view.
  List<AggregatedCard> _aggregate(List<MtgCard> cards) {
    final folderName = {for (final f in _folders) f.id: f.name};
    final byKey = <String, List<MtgCard>>{};
    for (final c in cards) {
      final key = '${c.setCode}|${c.collectorNumber}|${c.foil}';
      byKey.putIfAbsent(key, () => []).add(c);
    }
    final result = byKey.values.map((entries) {
      final first = entries.first;
      final locations = entries
          .map((c) => (
                label: c.folderId == null
                    ? 'Unfiled'
                    : (folderName[c.folderId] ?? 'Folder'),
                qty: c.quantity,
              ))
          .toList()
        ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return AggregatedCard(
        name: first.name,
        setCode: first.setCode,
        collectorNumber: first.collectorNumber,
        foil: first.foil,
        imageUrl: first.imageUrl,
        priceUsd: first.priceUsd,
        colors: first.colors,
        total: entries.fold(0, (s, c) => s + c.quantity),
        locations: locations,
      );
    }).toList();
    _sortAggregated(result);
    return result;
  }

  /// Sorts aggregated tiles by the active [_sort]/[_sortAscending], mirroring
  /// the ordering the database applies to non-aggregated views.
  void _sortAggregated(List<AggregatedCard> list) {
    int cmp(AggregatedCard a, AggregatedCard b) {
      switch (_sort) {
        case CardSort.setNumber:
          final s =
              a.setCode.toLowerCase().compareTo(b.setCode.toLowerCase());
          if (s != 0) return s;
          final an = int.tryParse(a.collectorNumber);
          final bn = int.tryParse(b.collectorNumber);
          if (an != null && bn != null) return an.compareTo(bn);
          return a.collectorNumber.compareTo(b.collectorNumber);
        case CardSort.price:
          return (a.priceUsd ?? 0).compareTo(b.priceUsd ?? 0);
        case CardSort.quantity:
          return a.total.compareTo(b.total);
        case CardSort.color:
          final c = MtgCard.colorRank(a.colors)
              .compareTo(MtgCard.colorRank(b.colors));
          return c != 0
              ? c
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case CardSort.name:
        case CardSort.dateAdded:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    }

    list.sort((a, b) => _sortAscending ? cmp(a, b) : -cmp(a, b));
  }

  /// Changes the sort field/direction and reloads.
  Future<void> setSort(CardSort sort, bool ascending) async {
    _sort = sort;
    _sortAscending = ascending;
    await load();
  }

  /// Sets the search query (name/text) and reloads.
  Future<void> setQuery(String value) async {
    _query = value;
    await load();
  }

  /// Selects which folder to show: null = All cards, [unfiledSentinel] =
  /// Unfiled, otherwise a folder id.
  Future<void> selectFolder(int? folderId) async {
    _selectedFolderId = folderId;
    await load();
  }

  /// Adds a card, merging into an existing matching printing if present.
  Future<AddResult> addCard(MtgCard card) async {
    final result = await _db.addOrMergeCard(card);
    await load();
    return result;
  }

  /// Persists edits to an existing card entry.
  Future<void> updateCard(MtgCard card) async {
    await _db.updateCard(card);
    await load();
  }

  /// Deletes a single card entry by id.
  Future<void> deleteCard(int cardId) async {
    await _db.deleteCard(cardId);
    await load();
  }

  /// Moves a whole card entry into [destFolderId] (null = Unfiled), merging
  /// with any existing matching entry there.
  Future<void> moveCard(MtgCard card, int? destFolderId) async {
    await _db.moveQuantityToFolder(card, card.quantity, destFolderId);
    await load();
  }

  /// Moves [qty] copies of [card] into [destFolderId], leaving the rest where
  /// they are — used to split a stack across folders.
  Future<void> splitCard(MtgCard card, int qty, int? destFolderId) async {
    await _db.moveQuantityToFolder(card, qty, destFolderId);
    await load();
  }

  /// Moves several whole entries into [destFolderId] (bulk selection move).
  Future<void> moveCards(List<MtgCard> cards, int? destFolderId) async {
    for (final c in cards) {
      await _db.moveQuantityToFolder(c, c.quantity, destFolderId);
    }
    await load();
  }

  /// Deletes several entries by id (bulk selection delete).
  Future<void> deleteCards(List<int> cardIds) async {
    await _db.deleteCards(cardIds);
    await load();
  }

  /// Re-fetches current USD prices from Scryfall for every card and updates the
  /// stored values (foil-aware). Returns how many rows changed.
  Future<PriceRefreshResult> refreshPrices() async {
    final all = await _db.getCards();
    if (all.isEmpty) return const PriceRefreshResult(updated: 0, total: 0);

    final scryfall = ScryfallService();
    try {
      // Unique printing identifiers for the batch lookup.
      final byKey = <String, Map<String, String>>{};
      for (final c in all) {
        byKey['${c.setCode.toLowerCase()}|${c.collectorNumber}'] = {
          'set': c.setCode.toLowerCase(),
          'collector_number': c.collectorNumber,
        };
      }
      final result = await scryfall.getCollection(byKey.values.toList());
      final jsonByKey = <String, Map<String, dynamic>>{
        for (final j in result.found)
          '${(j['set'] as String).toLowerCase()}|${j['collector_number']}': j,
      };

      var updated = 0;
      for (final c in all) {
        final json = jsonByKey['${c.setCode.toLowerCase()}|${c.collectorNumber}'];
        if (json == null) continue;
        final price = MtgCard.fromScryfall(json, foil: c.foil).priceUsd;
        if (price != null && price != c.priceUsd) {
          await _db.setCardPrice(c.id!, price);
          updated++;
        }
      }
      await load();
      return PriceRefreshResult(updated: updated, total: all.length);
    } finally {
      scryfall.dispose();
    }
  }

  /// Creates a new folder and reloads.
  Future<void> addFolder(String name) async {
    await _db.addFolder(name);
    await load();
  }

  /// Renames an existing folder and reloads.
  Future<void> renameFolder(int id, String name) async {
    await _db.renameFolder(id, name);
    await load();
  }

  Future<void> deleteFolder(int id) async {
    // If we were viewing the deleted folder, fall back to All cards.
    if (_selectedFolderId == id) _selectedFolderId = null;
    await _db.deleteFolder(id);
    await load();
  }
}

/// Result of [CollectionStore.refreshPrices].
class PriceRefreshResult {
  const PriceRefreshResult({required this.updated, required this.total});

  /// Number of card entries whose stored price changed.
  final int updated;

  /// Total number of card entries checked.
  final int total;
}

/// Result of [CollectionStore.backfillCardDetails].
class DetailBackfillResult {
  const DetailBackfillResult({required this.updated, required this.total});

  /// Number of card entries enriched with detail fields.
  final int updated;

  /// Number of entries that needed backfilling (were missing details).
  final int total;
}

/// A printing (set + collector number + foil) combined across folders, with the
/// total owned and a per-location breakdown. Used by the "All cards" view.
class AggregatedCard {
  AggregatedCard({
    required this.name,
    required this.setCode,
    required this.collectorNumber,
    required this.foil,
    required this.imageUrl,
    required this.priceUsd,
    required this.colors,
    required this.total,
    required this.locations,
  });

  final String name;
  final String setCode;
  final String collectorNumber;
  final bool foil;
  final String? imageUrl;
  final double? priceUsd;
  final String colors;

  /// Combined quantity across all folder locations.
  final int total;

  /// Per-location breakdown: the folder label ("Unfiled" or a folder name) and
  /// how many copies live there.
  final List<({String label, int qty})> locations;

  /// True when this printing is split across more than one folder.
  bool get isSplit => locations.length > 1;
}
