import 'package:flutter/material.dart';

import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/folder.dart';
import '../models/mtg_card.dart';
import '../services/collection_store.dart';
import '../services/database_service.dart';
import '../services/deck_store.dart';
import '../services/scryfall_service.dart';
import '../widgets/card_image.dart';
import '../widgets/tags.dart';

/// Collection tab: browse all stored cards with a folder sidebar and a
/// search/filter bar. Cards always live in the overall collection and may be
/// filed into at most one folder.
class CollectionTab extends StatefulWidget {
  const CollectionTab({super.key, required this.store, required this.deckStore});

  final CollectionStore store;
  final DeckStore deckStore;

  @override
  State<CollectionTab> createState() => _CollectionTabState();
}

class _CollectionTabState extends State<CollectionTab> {
  final _searchController = TextEditingController();

  /// Multi-select state for bulk actions like moving cards into a folder.
  bool _selectionMode = false;
  final Set<int> _selected = {};

  /// Tracks the active folder so selection can reset when it changes.
  int? _activeFolder;

  @override
  void initState() {
    super.initState();
    _searchController.text = widget.store.query;
    _activeFolder = widget.store.selectedFolderId;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Toggles whether [cardId] is in the multi-select set.
  void _toggleSelection(int cardId) {
    setState(() {
      if (!_selected.remove(cardId)) _selected.add(cardId);
    });
  }

  /// Leaves multi-select mode and clears the selection.
  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  /// Prompts for a destination folder and moves all selected cards there.
  Future<void> _bulkMove() async {
    if (_selected.isEmpty) return;
    final result = await _pickFolder(
      context,
      widget.store,
      title: 'Move ${_selected.length} card'
          '${_selected.length == 1 ? '' : 's'} to…',
    );
    if (result == null) return;
    final cards =
        widget.store.cards.where((c) => _selected.contains(c.id)).toList();
    await widget.store.moveCards(cards, result.folderId);
    if (!mounted) return;
    _exitSelection();
    final dest = result.folderId == null
        ? 'Unfiled'
        : widget.store.folders
            .firstWhere((f) => f.id == result.folderId)
            .name;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Moved ${cards.length} card'
          '${cards.length == 1 ? '' : 's'} to $dest.')),
    );
  }

  /// Confirms and permanently deletes all selected cards.
  Future<void> _bulkDelete() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $count card${count == 1 ? '' : 's'}?'),
        content: const Text(
          'This permanently removes the selected cards from your collection. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ids = _selected.toList();
    await widget.store.deleteCards(ids);
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted ${ids.length} card'
          '${ids.length == 1 ? '' : 's'}.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        // Leaving selection mode when the active folder changes (selection is
        // per-entry and doesn't carry across views).
        if (_activeFolder != widget.store.selectedFolderId) {
          _activeFolder = widget.store.selectedFolderId;
          _selectionMode = false;
          _selected.clear();
        }
        return Row(
          children: [
            _FolderSidebar(store: widget.store),
            const VerticalDivider(width: 1),
            Expanded(child: _buildMain(context)),
          ],
        );
      },
    );
  }

  /// The main pane right of the sidebar: search/sort/tag/count/select bar, an
  /// optional selection action bar, and the card grid.
  Widget _buildMain(BuildContext context) {
    final store = widget.store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search by name, set code, or collector number…',
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: store.query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              store.setQuery('');
                            },
                          ),
                  ),
                  onChanged: store.setQuery,
                ),
              ),
              const SizedBox(width: 12),
              _buildSortControl(context, store),
              const SizedBox(width: 8),
              _buildTagFilter(context, store),
              const SizedBox(width: 16),
              Text(
                _countLabel(store),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(width: 12),
              // Selection (bulk move/delete) acts on individual entries, so it's
              // only available in a specific folder or Unfiled, not the combined
              // "All cards" view.
              if (!store.isAggregated)
                OutlinedButton.icon(
                  onPressed: store.cards.isEmpty
                      ? null
                      : () => setState(() {
                            _selectionMode = !_selectionMode;
                            if (!_selectionMode) _selected.clear();
                          }),
                  icon: Icon(
                    _selectionMode ? Icons.close : Icons.checklist,
                  ),
                  label: Text(_selectionMode ? 'Cancel' : 'Select'),
                ),
            ],
          ),
        ),
        if (_selectionMode && !store.isAggregated)
          _buildSelectionBar(context, store),
        Expanded(child: _buildGrid(context, store)),
      ],
    );
  }

  /// Summary line for the current view: unique/total counts and total value
  /// (the "unique" figure only applies to the aggregated "All cards" view).
  String _countLabel(CollectionStore store) {
    final value = _money(store.totalValue);
    if (store.isAggregated) {
      final unique = store.aggregatedCards.length;
      return '$unique unique • ${store.totalCards} total • $value';
    }
    return '${store.cards.length} card'
        '${store.cards.length == 1 ? '' : 's'} • ${store.totalCards} total • $value';
  }

  /// Formats a USD amount with a thousands separator, e.g. 1234.5 -> "\$1,234.50".
  static String _money(double value) {
    final fixed = value.toStringAsFixed(2);
    final dot = fixed.indexOf('.');
    final intPart = fixed.substring(0, dot);
    final decPart = fixed.substring(dot + 1);
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '\$$buf.$decPart';
  }

  /// The responsive card grid: [_AggregatedTile]s in the "All cards" view or
  /// interactive [_CardTile]s in a specific folder/Unfiled view.
  Widget _buildGrid(BuildContext context, CollectionStore store) {
    final isEmpty = store.isAggregated
        ? store.aggregatedCards.isEmpty
        : store.cards.isEmpty;
    if (isEmpty) {
      return Center(
        child: Text(
          store.query.isNotEmpty
              ? 'No cards match your search.'
              : 'No cards here yet. Add some from the Import tab.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    final count =
        store.isAggregated ? store.aggregatedCards.length : store.cards.length;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: count,
      itemBuilder: (context, i) {
        if (store.isAggregated) {
          return _AggregatedTile(card: store.aggregatedCards[i]);
        }
        final card = store.cards[i];
        return _CardTile(
          card: card,
          store: store,
          deckStore: widget.deckStore,
          selectionMode: _selectionMode,
          selected: _selected.contains(card.id),
          onToggle: () => _toggleSelection(card.id!),
        );
      },
    );
  }

  /// Human-readable label for a [CardSort] option.
  static String _sortLabel(CardSort s) {
    switch (s) {
      case CardSort.name:
        return 'Name';
      case CardSort.setNumber:
        return 'Set / number';
      case CardSort.color:
        return 'Color';
      case CardSort.price:
        return 'Price';
      case CardSort.quantity:
        return 'Quantity';
      case CardSort.dateAdded:
        return 'Recently added';
    }
  }

  /// The sort dropdown plus an ascending/descending toggle button.
  Widget _buildSortControl(BuildContext context, CollectionStore store) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<CardSort>(
          tooltip: 'Sort by',
          onSelected: (s) => store.setSort(s, store.sortAscending),
          itemBuilder: (_) => [
            for (final s in CardSort.values)
              CheckedPopupMenuItem(
                value: s,
                checked: store.sort == s,
                child: Text(_sortLabel(s)),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort, size: 18),
                const SizedBox(width: 6),
                Text('Sort: ${_sortLabel(store.sort)}'),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: store.sortAscending ? 'Ascending' : 'Descending',
          icon: Icon(
            store.sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 18,
          ),
          onPressed: () => store.setSort(store.sort, !store.sortAscending),
        ),
      ],
    );
  }

  /// The tag-filter dropdown; toggling tags updates the store's tag filter.
  Widget _buildTagFilter(BuildContext context, CollectionStore store) {
    // Offer the presets plus any custom tags currently in view.
    final tags = <String>{
      ...kTradeTags,
      for (final c in store.cards) ...c.tags,
    }.toList();
    final active = store.selectedTags;
    return PopupMenuButton<String>(
      tooltip: 'Filter by tag',
      onSelected: (tag) {
        if (tag.isEmpty) {
          store.setTagFilter({});
          return;
        }
        final next = {...active};
        if (!next.remove(tag)) next.add(tag);
        store.setTagFilter(next);
      },
      itemBuilder: (_) => [
        for (final t in tags)
          CheckedPopupMenuItem(
            value: t,
            checked: active.contains(t),
            child: Text(t),
          ),
        if (active.isNotEmpty)
          const PopupMenuItem(value: '', child: Text('Clear filter')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sell_outlined,
                size: 18,
                color: active.isEmpty
                    ? null
                    : Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(active.isEmpty ? 'Tags' : 'Tags (${active.length})'),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }

  /// The bulk-action bar shown in selection mode: selected count, select/clear
  /// all, and Delete / Move-to-folder actions.
  Widget _buildSelectionBar(BuildContext context, CollectionStore store) {
    final scheme = Theme.of(context).colorScheme;
    final visibleIds = store.cards.map((c) => c.id!).toSet();
    final allSelected =
        visibleIds.isNotEmpty && _selected.containsAll(visibleIds);
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Text(
              '${_selected.length} selected',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(width: 16),
            TextButton(
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.removeAll(visibleIds);
                } else {
                  _selected.addAll(visibleIds);
                }
              }),
              child: Text(allSelected ? 'Clear all' : 'Select all'),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _selected.isEmpty ? null : _bulkDelete,
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
              ),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _selected.isEmpty ? null : _bulkMove,
              icon: const Icon(Icons.drive_file_move_outline),
              label: const Text('Move to folder…'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Left sidebar listing "All cards", "Unfiled", and each folder (with counts
/// and rename/delete menus), plus a New-folder button.
class _FolderSidebar extends StatelessWidget {
  const _FolderSidebar({required this.store});

  final CollectionStore store;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Text('Folders', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'New folder',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: () => _createFolder(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                _navTile(
                  context,
                  icon: Icons.all_inbox,
                  label: 'All cards',
                  selected: store.selectedFolderId == null,
                  onTap: () => store.selectFolder(null),
                ),
                _navTile(
                  context,
                  icon: Icons.inbox_outlined,
                  label: 'Unfiled',
                  selected: store.selectedFolderId == unfiledSentinel,
                  onTap: () => store.selectFolder(unfiledSentinel),
                ),
                const Divider(),
                for (final folder in store.folders)
                  _navTile(
                    context,
                    icon: Icons.folder_outlined,
                    label: folder.name,
                    count: store.folderCounts[folder.id] ?? 0,
                    selected: store.selectedFolderId == folder.id,
                    onTap: () => store.selectFolder(folder.id),
                    onRename: () => _renameFolder(context, folder),
                    onDelete: () => _deleteFolder(context, folder),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One sidebar row. Shows a trailing count and, for real folders, a
  /// rename/delete menu ([onRename]/[onDelete] are null for the fixed rows).
  Widget _navTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    int? count,
    VoidCallback? onRename,
    VoidCallback? onDelete,
  }) {
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(icon),
      title: Text(label, overflow: TextOverflow.ellipsis),
      trailing: onRename == null && onDelete == null
          ? (count != null ? Text('$count') : null)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (count != null)
                  Text('$count',
                      style: Theme.of(context).textTheme.bodySmall),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (v) {
                    if (v == 'rename') onRename?.call();
                    if (v == 'delete') onDelete?.call();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
      onTap: onTap,
    );
  }

  /// Prompts for a name and creates a folder.
  Future<void> _createFolder(BuildContext context) async {
    final name = await _promptForName(context, title: 'New folder');
    if (name != null && name.isNotEmpty) await store.addFolder(name);
  }

  /// Prompts for a new name and renames [folder].
  Future<void> _renameFolder(BuildContext context, Folder folder) async {
    final name = await _promptForName(
      context,
      title: 'Rename folder',
      initial: folder.name,
    );
    if (name != null && name.isNotEmpty) {
      await store.renameFolder(folder.id!, name);
    }
  }

  /// Confirms and deletes [folder]; its cards become unfiled, not deleted.
  Future<void> _deleteFolder(BuildContext context, Folder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${folder.name}"?'),
        content: const Text(
          'Cards in this folder will stay in your collection but become '
          'unfiled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await store.deleteFolder(folder.id!);
  }
}

/// A single collection card tile: image with foil/quantity/tag badges and a
/// per-card action menu (edit tags, add to deck, move/split folder, edit
/// quantity, delete). In selection mode it shows a check overlay and toggles
/// on tap instead.
class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.card,
    required this.store,
    required this.deckStore,
    this.selectionMode = false,
    this.selected = false,
    this.onToggle,
  });

  final MtgCard card;
  final CollectionStore store;
  final DeckStore deckStore;

  /// Whether the grid is in multi-select mode.
  final bool selectionMode;

  /// Whether this tile is currently selected.
  final bool selected;

  /// Called when tapped in selection mode.
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tile = Card(
      clipBehavior: Clip.antiAlias,
      shape: selected
          ? RoundedRectangleBorder(
              side: BorderSide(color: scheme.primary, width: 3),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: CardImage(url: card.imageUrl),
                ),
                if (card.foil)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _badge(context, Icons.auto_awesome, 'Foil'),
                  ),
                if (selectionMode)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected ? scheme.primary : Colors.white,
                      shadows: const [Shadow(blurRadius: 4)],
                    ),
                  ),
                if (card.tags.isNotEmpty)
                  Positioned(
                    bottom: 6,
                    left: 6,
                    right: 6,
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final tag in card.tags) _tagBadge(context, tag),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      // Quantity lives here (bold) rather than over the card's
                      // mana cost, alongside the set/number and price.
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '×${card.quantity}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: scheme.primary,
                              ),
                            ),
                            TextSpan(
                              text: ' • ${card.setCode} #${card.collectorNumber}'
                                  '${card.priceUsd != null ? ' • \$${card.priceUsd!.toStringAsFixed(2)}' : ''}',
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (!selectionMode)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (v) => _onAction(context, v),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'tags', child: Text('Edit tags…')),
                      const PopupMenuItem(
                          value: 'add_to_deck', child: Text('Add to deck…')),
                      const PopupMenuItem(
                          value: 'move', child: Text('Move to folder…')),
                      if (card.quantity > 1)
                        const PopupMenuItem(
                            value: 'split', child: Text('Split to folder…')),
                      const PopupMenuItem(
                          value: 'quantity', child: Text('Edit quantity…')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!selectionMode) return tile;
    return GestureDetector(onTap: onToggle, child: tile);
  }

  /// A small translucent overlay badge (optional [icon] + [text]) drawn on the
  /// card image, e.g. "Foil" or "×3".
  Widget _badge(BuildContext context, IconData? icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: Colors.amber),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// A small colored tag chip overlaid on the card image.
  Widget _tagBadge(BuildContext context, String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tagColor(tag),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        tag,
        style: const TextStyle(
            color: Colors.black87, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// Dispatches the per-card menu selection to the matching handler.
  void _onAction(BuildContext context, String action) {
    switch (action) {
      case 'tags':
        _editTags(context);
      case 'add_to_deck':
        _addToDeck(context);
      case 'move':
        _moveToFolder(context);
      case 'split':
        _splitToFolder(context);
      case 'quantity':
        _editQuantity(context);
      case 'delete':
        store.deleteCard(card.id!);
    }
  }

  /// Opens the tag editor for this card and saves the result.
  Future<void> _editTags(BuildContext context) async {
    final result = await showTagEditor(context, card.tags);
    if (result != null) await store.setTags(card, result);
  }

  /// Adds this card to a chosen deck/board. Enriches it with cmc/type_line from
  /// Scryfall (not stored in the collection) so it groups and curves correctly,
  /// falling back to the stored fields if the lookup fails.
  Future<void> _addToDeck(BuildContext context) async {
    if (deckStore.decks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create a deck first (Decks tab).')),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final pick = await showDialog<_DeckPick>(
      context: context,
      builder: (_) => _DeckPickDialog(card: card, deckStore: deckStore),
    );
    if (pick == null) return;

    // Enrich with cmc / type_line from Scryfall so the card groups and curves
    // correctly (the collection doesn't store those). Falls back to the stored
    // fields if the lookup fails.
    final scryfall = ScryfallService();
    DeckCard deckCard;
    try {
      final json = await scryfall.getBySetAndNumber(
          card.setCode, card.collectorNumber);
      deckCard = json != null
          ? DeckCard.fromScryfall(json,
              deckId: pick.deckId, foil: card.foil, board: pick.board)
          : _deckCardFromCollection(pick.deckId, pick.board);
    } catch (_) {
      deckCard = _deckCardFromCollection(pick.deckId, pick.board);
    } finally {
      scryfall.dispose();
    }

    await deckStore.addCard(deckCard);
    final deckName = deckStore.decks
        .firstWhere((d) => d.id == pick.deckId,
            orElse: () => const Deck(name: 'deck'))
        .name;
    messenger.showSnackBar(
      SnackBar(content: Text('Added ${card.name} to "$deckName".')),
    );
  }

  /// Builds a [DeckCard] from this collection card's stored fields (used when
  /// the Scryfall enrichment in [_addToDeck] is unavailable).
  DeckCard _deckCardFromCollection(int deckId, String board) {
    return DeckCard(
      deckId: deckId,
      name: card.name,
      setCode: card.setCode,
      collectorNumber: card.collectorNumber,
      foil: card.foil,
      quantity: 1,
      imageUrl: card.imageUrl,
      priceUsd: card.priceUsd,
      colors: card.colors,
      colorIdentity: card.colorIdentity,
      board: board,
    );
  }

  /// Moves this whole card entry to a chosen folder.
  Future<void> _moveToFolder(BuildContext context) async {
    final result = await _pickFolder(
      context,
      store,
      title: 'Move "${card.name}"',
      currentFolderId: card.folderId,
    );
    if (result != null) {
      await store.moveCard(card, result.folderId);
    }
  }

  /// Moves part of this stack to another folder (leaves the rest in place).
  Future<void> _splitToFolder(BuildContext context) async {
    final result = await showDialog<_SplitResult>(
      context: context,
      builder: (_) => _SplitDialog(card: card, store: store),
    );
    if (result != null) {
      await store.splitCard(card, result.qty, result.folderId);
    }
  }

  /// Prompts for a new quantity and updates this entry.
  Future<void> _editQuantity(BuildContext context) async {
    final controller = TextEditingController(text: '${card.quantity}');
    final qty = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit quantity'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Quantity',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (qty != null && qty > 0) {
      await store.updateCard(card.copyWith(quantity: qty));
    }
  }
}

/// Read-only tile for the combined "All cards" view: one printing with its
/// total across folders and a per-folder breakdown when split.
class _AggregatedTile extends StatelessWidget {
  const _AggregatedTile({required this.card});

  final AggregatedCard card;

  @override
  Widget build(BuildContext context) {
    final breakdown =
        card.locations.map((l) => '${l.label} ×${l.qty}').join(' • ');
    final tile = Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: CardImage(url: card.imageUrl)),
                if (card.foil)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _badge(context, Icons.auto_awesome, 'Foil'),
                  ),
                if (card.isSplit)
                  Positioned(
                    bottom: 6,
                    left: 6,
                    child: _badge(
                      context,
                      Icons.folder_copy_outlined,
                      '${card.locations.length} folders',
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                // Total owned (bold) shown here rather than over the mana cost.
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '×${card.total}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      TextSpan(
                        text: ' • ${card.setCode} #${card.collectorNumber}'
                            '${card.priceUsd != null ? ' • \$${card.priceUsd!.toStringAsFixed(2)}' : ''}',
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (card.isSplit)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      breakdown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!card.isSplit) return tile;
    return Tooltip(
      message: card.locations.map((l) => '${l.label}: ${l.qty}').join('\n'),
      child: tile,
    );
  }

  /// A small translucent overlay badge (optional [icon] + [text]) on the image.
  Widget _badge(BuildContext context, IconData? icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: Colors.amber),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Result of the folder chooser: the destination folder id, or null = Unfiled.
class _MoveResult {
  const _MoveResult({required this.folderId});
  final int? folderId;
}

/// Result of [_DeckPickDialog]: the chosen deck and target board.
class _DeckPick {
  const _DeckPick({required this.deckId, required this.board});
  final int deckId;
  final String board;
}

/// Dialog to choose which deck (and board) to add a collection card to.
class _DeckPickDialog extends StatefulWidget {
  const _DeckPickDialog({required this.card, required this.deckStore});

  final MtgCard card;
  final DeckStore deckStore;

  @override
  State<_DeckPickDialog> createState() => _DeckPickDialogState();
}

class _DeckPickDialogState extends State<_DeckPickDialog> {
  late int _deckId = widget.deckStore.decks.first.id!;
  String _board = DeckBoard.main;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add "${widget.card.name}" to deck'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<int>(
            isExpanded: true,
            value: _deckId,
            items: [
              for (final d in widget.deckStore.decks)
                DropdownMenuItem(value: d.id, child: Text(d.name)),
            ],
            onChanged: (v) => setState(() => _deckId = v!),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: DeckBoard.commander, label: Text('Cmdr')),
              ButtonSegment(value: DeckBoard.main, label: Text('Main')),
              ButtonSegment(value: DeckBoard.side, label: Text('Side')),
            ],
            selected: {_board},
            onSelectionChanged: (s) => setState(() => _board = s.first),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Adding to a deck does not change your collection.'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
              context, _DeckPick(deckId: _deckId, board: _board)),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Result of [_SplitDialog]: how many copies to move and to which folder
/// (null = Unfiled).
class _SplitResult {
  const _SplitResult({required this.qty, required this.folderId});
  final int qty;
  final int? folderId;
}

/// Dialog to move part of a stack into another folder (split a quantity).
class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.card, required this.store});

  final MtgCard card;
  final CollectionStore store;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  late int _qty = 1;

  /// Destination options, encoded as folder ids with [unfiledSentinel] for
  /// "Unfiled". Excludes the card's current folder.
  late final List<({int value, String label})> _destinations = [
    if (widget.card.folderId != null)
      (value: unfiledSentinel, label: 'Unfiled (no folder)'),
    for (final f in widget.store.folders)
      if (f.id != widget.card.folderId) (value: f.id!, label: f.name),
  ];

  late int? _dest = _destinations.isEmpty ? null : _destinations.first.value;

  @override
  Widget build(BuildContext context) {
    final max = widget.card.quantity;
    if (_destinations.isEmpty) {
      return AlertDialog(
        title: Text('Split "${widget.card.name}"'),
        content: const Text(
          'There is nowhere to move copies to. Create another folder first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text('Split "${widget.card.name}"'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You have $max. Move how many, and where?'),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Move'),
              IconButton(
                onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$_qty', style: Theme.of(context).textTheme.titleMedium),
              IconButton(
                onPressed: _qty < max ? () => setState(() => _qty++) : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
              Text(_qty == max ? 'copies (all)' : 'copies'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('to '),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _dest,
                  items: [
                    for (final d in _destinations)
                      DropdownMenuItem(value: d.value, child: Text(d.label)),
                  ],
                  onChanged: (v) => setState(() => _dest = v),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _SplitResult(
              qty: _qty,
              folderId: _dest == unfiledSentinel ? null : _dest,
            ),
          ),
          child: const Text('Move'),
        ),
      ],
    );
  }
}

/// Shows the folder chooser used by both single- and multi-card moves.
///
/// Returns null if cancelled, or a [_MoveResult] whose `folderId` is the chosen
/// folder (or null for "Unfiled"). [currentFolderId] marks the active folder
/// with a check when moving a single card.
Future<_MoveResult?> _pickFolder(
  BuildContext context,
  CollectionStore store, {
  required String title,
  int? currentFolderId,
}) {
  return showDialog<_MoveResult>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, const _MoveResult(folderId: null)),
          child: Row(
            children: [
              const Icon(Icons.inbox_outlined),
              const SizedBox(width: 12),
              const Text('Unfiled (no folder)'),
              if (currentFolderId == null) ...[
                const Spacer(),
                const Icon(Icons.check, size: 18),
              ],
            ],
          ),
        ),
        const Divider(),
        for (final folder in store.folders)
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(ctx, _MoveResult(folderId: folder.id)),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 12),
                Expanded(child: Text(folder.name)),
                if (currentFolderId == folder.id)
                  const Icon(Icons.check, size: 18),
              ],
            ),
          ),
        if (store.folders.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No folders yet. Create one from the sidebar.'),
          ),
      ],
    ),
  );
}

/// A folder name-entry dialog (create/rename); returns the trimmed name or null
/// if cancelled. Local to this file so the label reads "Folder name".
Future<String?> _promptForName(
  BuildContext context, {
  required String title,
  String? initial,
}) {
  final controller = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Folder name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
