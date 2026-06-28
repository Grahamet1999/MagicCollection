import 'package:flutter/material.dart';

import '../models/folder.dart';
import '../models/mtg_card.dart';
import '../services/collection_store.dart';
import '../services/database_service.dart';
import '../widgets/card_image.dart';

/// Collection tab: browse all stored cards with a folder sidebar and a
/// search/filter bar. Cards always live in the overall collection and may be
/// filed into at most one folder.
class CollectionTab extends StatefulWidget {
  const CollectionTab({super.key, required this.store});

  final CollectionStore store;

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

  void _toggleSelection(int cardId) {
    setState(() {
      if (!_selected.remove(cardId)) _selected.add(cardId);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

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
          selectionMode: _selectionMode,
          selected: _selected.contains(card.id),
          onToggle: () => _toggleSelection(card.id!),
        );
      },
    );
  }

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

  Future<void> _createFolder(BuildContext context) async {
    final name = await _promptForName(context, title: 'New folder');
    if (name != null && name.isNotEmpty) await store.addFolder(name);
  }

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

class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.card,
    required this.store,
    this.selectionMode = false,
    this.selected = false,
    this.onToggle,
  });

  final MtgCard card;
  final CollectionStore store;
  final bool selectionMode;
  final bool selected;
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
                Positioned(
                  top: 6,
                  right: 6,
                  child: _badge(context, null, '×${card.quantity}'),
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
                      Text(
                        '${card.setCode} #${card.collectorNumber}'
                        '${card.priceUsd != null ? ' • \$${card.priceUsd!.toStringAsFixed(2)}' : ''}',
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

  void _onAction(BuildContext context, String action) {
    switch (action) {
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

  Future<void> _splitToFolder(BuildContext context) async {
    final result = await showDialog<_SplitResult>(
      context: context,
      builder: (_) => _SplitDialog(card: card, store: store),
    );
    if (result != null) {
      await store.splitCard(card, result.qty, result.folderId);
    }
  }

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
                Positioned(
                  top: 6,
                  right: 6,
                  child: _badge(context, null, '×${card.total}'),
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
                Text(
                  '${card.setCode} #${card.collectorNumber}'
                  '${card.priceUsd != null ? ' • \$${card.priceUsd!.toStringAsFixed(2)}' : ''}',
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

class _MoveResult {
  const _MoveResult({required this.folderId});
  final int? folderId;
}

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
