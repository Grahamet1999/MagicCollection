import 'package:flutter/material.dart';

import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/scryfall_parse.dart';
import '../services/deck_store.dart';
import '../services/scryfall_service.dart';
import '../widgets/card_image.dart';
import '../widgets/dialogs.dart';

/// Selectable format labels for the deck's format dropdown.
const List<String> _formats = [
  'Commander',
  'Standard',
  'Pioneer',
  'Modern',
  'Pauper',
  'Legacy',
  'Vintage',
  'Brawl',
  'Freeform',
];

/// Deck-building tab: a deck list sidebar plus the selected deck's contents
/// (commander, mainboard grouped by type, sideboard), stats, mana curve, and a
/// Scryfall add panel filtered to the commander's color identity.
class DecksTab extends StatefulWidget {
  const DecksTab({super.key, required this.store});

  final DeckStore store;

  @override
  State<DecksTab> createState() => _DecksTabState();
}

class _DecksTabState extends State<DecksTab> {
  /// Scryfall client for the add-card search (owned by this tab).
  final _scryfall = ScryfallService();
  final _searchController = TextEditingController();

  /// True while a Scryfall search is in flight.
  bool _loading = false;

  /// Last search error message, or null.
  String? _error;

  /// Raw Scryfall JSON results for the add panel.
  List<Map<String, dynamic>> _searchResults = [];

  /// Which board added cards go to (main or side); commander is set separately.
  String _addBoard = DeckBoard.main;

  @override
  void dispose() {
    _scryfall.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Shorthand for the deck store this tab renders.
  DeckStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Row(
          children: [
            _buildSidebar(context),
            const VerticalDivider(width: 1),
            Expanded(child: _buildContent(context)),
          ],
        );
      },
    );
  }

  // ---- Sidebar -------------------------------------------------------------

  /// The left deck-list column: a "New deck" button and every deck with its
  /// card count and a rename/delete menu.
  Widget _buildSidebar(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Text('Decks', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'New deck',
                  icon: const Icon(Icons.add),
                  onPressed: () => _createDeck(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: store.decks.isEmpty
                ? Center(
                    child: Text('No decks yet.',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline)),
                  )
                : ListView(
                    children: [
                      for (final deck in store.decks)
                        ListTile(
                          dense: true,
                          selected: deck.id == store.selectedDeckId,
                          leading: const Icon(Icons.dashboard_customize_outlined),
                          title:
                              Text(deck.name, overflow: TextOverflow.ellipsis),
                          subtitle: deck.format == null
                              ? null
                              : Text(deck.format!),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${store.deckCounts[deck.id] ?? 0}',
                                  style:
                                      Theme.of(context).textTheme.bodySmall),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, size: 18),
                                onSelected: (v) {
                                  if (v == 'rename') _renameDeck(context, deck);
                                  if (v == 'delete') _deleteDeck(context, deck);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'rename', child: Text('Rename')),
                                  PopupMenuItem(
                                      value: 'delete', child: Text('Delete')),
                                ],
                              ),
                            ],
                          ),
                          onTap: () => store.selectDeck(deck.id),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ---- Deck content --------------------------------------------------------

  /// The right pane for the selected deck: header, stats, add panel, then the
  /// commander / mainboard-by-type / sideboard sections. Prompts to create a
  /// deck when none is selected.
  Widget _buildContent(BuildContext context) {
    final deck = store.selectedDeck;
    if (deck == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Select or create a deck to start building.',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _createDeck(context),
              icon: const Icon(Icons.add),
              label: const Text('New deck'),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildHeader(context, deck),
        const SizedBox(height: 12),
        _buildStats(context),
        const SizedBox(height: 12),
        _buildAddPanel(context),
        const SizedBox(height: 16),
        if (store.commander != null) ...[
          _sectionHeader(context, 'Commander', store.commanderCount),
          _deckCardRow(context, store.commander!),
          const SizedBox(height: 16),
        ],
        _sectionHeader(context, 'Mainboard', store.mainboardCount),
        if (store.mainboard.isEmpty)
          _emptyHint(context, 'No mainboard cards yet — add some above.')
        else
          for (final entry in store.mainboardByType.entries) ...[
            _typeHeader(context, entry.key.label, _sum(entry.value)),
            for (final card in entry.value) _deckCardRow(context, card),
          ],
        const SizedBox(height: 16),
        _sectionHeader(context, 'Sideboard', store.sideboardCount),
        if (store.sideboard.isEmpty)
          _emptyHint(context, 'No sideboard cards.')
        else
          for (final card in store.sideboard) _deckCardRow(context, card),
      ],
    );
  }

  /// Sums the quantities of [cards] (used for the per-type header counts).
  int _sum(List<DeckCard> cards) => cards.fold(0, (s, c) => s + c.quantity);

  /// Deck name plus the format dropdown.
  Widget _buildHeader(BuildContext context, Deck deck) {
    return Row(
      children: [
        Expanded(
          child: Text(deck.name,
              style: Theme.of(context).textTheme.headlineSmall,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        const Text('Format:'),
        const SizedBox(width: 8),
        DropdownButton<String?>(
          value: _formats.contains(deck.format) ? deck.format : null,
          hint: const Text('None'),
          items: [
            const DropdownMenuItem(value: null, child: Text('None')),
            for (final f in _formats)
              DropdownMenuItem(value: f, child: Text(f)),
          ],
          onChanged: (v) => store.setFormat(deck.id!, v),
        ),
      ],
    );
  }

  /// Stats card: board counts, deck value, color pip breakdown, and the mana
  /// curve chart.
  Widget _buildStats(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _stat(context, 'Mainboard', '${store.mainboardCount}'),
                _stat(context, 'Sideboard', '${store.sideboardCount}'),
                _stat(context, 'Value',
                    '\$${store.deckValue.toStringAsFixed(2)}'),
                _colorBreakdown(context),
              ],
            ),
            const SizedBox(height: 12),
            Text('Mana curve',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            _manaCurve(context, scheme),
          ],
        ),
      ),
    );
  }

  /// A single labeled statistic (label above value).
  Widget _stat(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  /// Colored chips showing the pip count per color (omitting absent colors).
  Widget _colorBreakdown(BuildContext context) {
    const symbols = {
      'W': Color(0xFFF8F6D8),
      'U': Color(0xFFAAE0FA),
      'B': Color(0xFFCBC2BF),
      'R': Color(0xFFF9AA8F),
      'G': Color(0xFF9BD3AE),
    };
    final counts = store.colorBreakdown;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in symbols.entries)
          if ((counts[e.key] ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Chip(
                visualDensity: VisualDensity.compact,
                backgroundColor: e.value,
                label: Text('${e.key} ${counts[e.key]}',
                    style: const TextStyle(color: Colors.black87)),
              ),
            ),
      ],
    );
  }

  /// A small bar chart of the CMC histogram (buckets 0..7, where 7 = 7+),
  /// heights normalized to the tallest bar.
  Widget _manaCurve(BuildContext context, ColorScheme scheme) {
    final curve = store.manaCurve;
    final max = curve.values.fold(0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: 70,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i <= 7; i++)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('${curve[i] ?? 0}',
                      style: Theme.of(context).textTheme.labelSmall),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    height: max == 0
                        ? 2
                        : 4 + 44 * (curve[i] ?? 0) / max,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(i == 7 ? '7+' : '$i',
                      style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- Add panel -----------------------------------------------------------

  /// The add-card panel: a Scryfall name search (auto-filtered to the
  /// commander's color identity), a main/side target toggle, and tappable
  /// results that add to the deck.
  Widget _buildAddPanel(BuildContext context) {
    final ci = store.commanderColorIdentity;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Add cards — search by name',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: DeckBoard.main, label: Text('Main')),
                    ButtonSegment(value: DeckBoard.side, label: Text('Side')),
                  ],
                  selected: {_addBoard},
                  onSelectionChanged: (s) =>
                      setState(() => _addBoard = s.first),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _loading ? null : _search,
                  child: const Text('Search'),
                ),
              ],
            ),
            if (ci != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Filtered to commander color identity '
                  '(${ci.isEmpty ? 'colorless' : ci}).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ),
            if (_loading) const LinearProgressIndicator(),
            if (_searchResults.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _searchResults.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final json = _searchResults[i];
                    final set = (json['set'] as String? ?? '').toUpperCase();
                    final number = json['collector_number'] as String? ?? '';
                    return ListTile(
                      dense: true,
                      leading: CardImage(
                        url: _resultImage(json),
                        width: 34,
                        height: 48,
                      ),
                      title: Text(json['name'] as String? ?? 'Unknown'),
                      subtitle: Text('${json['type_line'] ?? ''} • $set #$number'),
                      trailing: const Icon(Icons.add),
                      onTap: () => _addResult(json),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Deck card row -------------------------------------------------------

  /// A section title ("Commander"/"Mainboard"/"Sideboard") with its count.
  Widget _sectionHeader(BuildContext context, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 8),
          Text('($count)',
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          const Expanded(child: Divider(indent: 12)),
        ],
      ),
    );
  }

  /// A card-type subheading within the mainboard (e.g. "Creatures (12)").
  Widget _typeHeader(BuildContext context, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2, left: 4),
      child: Text('$label ($count)',
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
  }

  /// A muted placeholder line shown for an empty board.
  Widget _emptyHint(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text,
          style: TextStyle(color: Theme.of(context).colorScheme.outline)),
    );
  }

  /// One card row: thumbnail, name/printing, an "owned in collection" badge
  /// (green when you own enough copies), quantity steppers, and a board/remove
  /// menu.
  Widget _deckCardRow(BuildContext context, DeckCard card) {
    final owned = store.ownedCount(card.name);
    final enough = owned >= card.quantity;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          CardImage(url: card.imageUrl, width: 32, height: 45),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(card.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  '${card.setCode} #${card.collectorNumber}'
                  '${card.foil ? ' • Foil' : ''}'
                  '${card.priceUsd != null ? ' • \$${card.priceUsd!.toStringAsFixed(2)}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Tooltip(
            message: 'Owned in collection',
            child: Chip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                enough ? Icons.check_circle : Icons.remove_circle_outline,
                size: 16,
                color: enough ? Colors.green : Colors.orange,
              ),
              label: Text('own $owned'),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove, size: 18),
            onPressed: card.quantity > 1
                ? () => store.setQuantity(card.id!, card.quantity - 1)
                : null,
          ),
          Text('${card.quantity}',
              style: Theme.of(context).textTheme.titleMedium),
          IconButton(
            icon: const Icon(Icons.add, size: 18),
            onPressed: () => store.setQuantity(card.id!, card.quantity + 1),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) => _onCardAction(context, card, v),
            itemBuilder: (_) => [
              if (card.board != DeckBoard.commander)
                const PopupMenuItem(
                    value: 'commander', child: Text('Set as commander')),
              if (card.board != DeckBoard.main)
                const PopupMenuItem(
                    value: 'main', child: Text('Move to mainboard')),
              if (card.board != DeckBoard.side)
                const PopupMenuItem(
                    value: 'side', child: Text('Move to sideboard')),
              const PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }

  /// Handles the per-card menu: set commander, move board, or remove.
  void _onCardAction(BuildContext context, DeckCard card, String action) {
    switch (action) {
      case 'commander':
        store.setCommander(card.id!);
      case 'main':
        store.setBoard(card.id!, DeckBoard.main);
      case 'side':
        store.setBoard(card.id!, DeckBoard.side);
      case 'remove':
        store.removeCard(card.id!);
    }
  }

  // ---- Actions -------------------------------------------------------------

  /// Extracts a thumbnail URL from a raw Scryfall result (deckId is irrelevant
  /// here, so 0 is passed as a throwaway).
  String? _resultImage(Map<String, dynamic> json) {
    return DeckCard.fromScryfall(json, deckId: 0).imageUrl;
  }

  /// Runs the Scryfall name search, filtered to the commander's color identity,
  /// and populates [_searchResults].
  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _searchResults = [];
    });
    try {
      final results = await _scryfall.searchByName(
        q,
        colorIdentity: store.commanderColorIdentity,
      );
      setState(() {
        _searchResults = results;
        if (results.isEmpty) _error = 'No cards matched "$q".';
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Adds a searched card to the selected deck on the current [_addBoard].
  Future<void> _addResult(Map<String, dynamic> json) async {
    final deckId = store.selectedDeckId;
    if (deckId == null) return;
    final card = DeckCard.fromScryfall(json, deckId: deckId, board: _addBoard);
    await store.addCard(card);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added ${card.name} to '
            '${_addBoard == DeckBoard.side ? 'sideboard' : 'mainboard'}.'),
      ),
    );
  }

  /// Prompts for a name and creates a new deck.
  Future<void> _createDeck(BuildContext context) async {
    final name = await promptForName(context,
        title: 'New deck', label: 'Deck name');
    if (name != null && name.isNotEmpty) await store.createDeck(name);
  }

  /// Prompts for a new name and renames [deck].
  Future<void> _renameDeck(BuildContext context, Deck deck) async {
    final name = await promptForName(context,
        title: 'Rename deck', label: 'Deck name', initial: deck.name);
    if (name != null && name.isNotEmpty) {
      await store.renameDeck(deck.id!, name);
    }
  }

  /// Confirms and deletes [deck] (and its cards; collection is unaffected).
  Future<void> _deleteDeck(BuildContext context, Deck deck) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${deck.name}"?'),
        content: const Text('This permanently deletes the deck and its cards. '
            'Your collection is unaffected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await store.deleteDeck(deck.id!);
  }
}
