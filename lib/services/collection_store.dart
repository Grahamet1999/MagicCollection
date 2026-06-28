import 'package:flutter/foundation.dart';

import '../models/folder.dart';
import '../models/mtg_card.dart';
import 'database_service.dart';

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
  int get totalCards => _cards.fold(0, (sum, c) => sum + c.quantity);

  Future<void> load() async {
    _folders = await _db.getFolders();
    _folderCounts = await _db.folderCardCounts();
    _cards = await _db.getCards(
      query: _query,
      folderId: _selectedFolderId,
      sort: _sort,
      ascending: _sortAscending,
    );
    _aggregated = isAggregated ? _aggregate(_cards) : const [];
    notifyListeners();
  }

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

  Future<void> setSort(CardSort sort, bool ascending) async {
    _sort = sort;
    _sortAscending = ascending;
    await load();
  }

  Future<void> setQuery(String value) async {
    _query = value;
    await load();
  }

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

  Future<void> updateCard(MtgCard card) async {
    await _db.updateCard(card);
    await load();
  }

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

  Future<void> moveCards(List<MtgCard> cards, int? destFolderId) async {
    for (final c in cards) {
      await _db.moveQuantityToFolder(c, c.quantity, destFolderId);
    }
    await load();
  }

  Future<void> deleteCards(List<int> cardIds) async {
    await _db.deleteCards(cardIds);
    await load();
  }

  Future<void> addFolder(String name) async {
    await _db.addFolder(name);
    await load();
  }

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
  final int total;
  final List<({String label, int qty})> locations;

  bool get isSplit => locations.length > 1;
}
