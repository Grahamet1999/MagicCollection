import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/deck.dart';
import '../models/deck_advice.dart';
import '../models/deck_card.dart';
import '../models/scryfall_parse.dart';
import '../services/database_service.dart';
import '../services/deck_analyzer.dart';
import '../services/deck_csv_export_service.dart';
import '../services/deck_csv_import_service.dart';
import '../services/deck_store.dart';
import '../services/edhrec_service.dart';
import '../services/recommendation_service.dart';
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

/// How the mainboard card list is split into sections.
enum _GroupBy {
  type,
  color,
  manaValue,
  none;

  String get label => switch (this) {
        _GroupBy.type => 'Type',
        _GroupBy.color => 'Color',
        _GroupBy.manaValue => 'Mana value',
        _GroupBy.none => 'None',
      };
}

/// How cards are ordered within each section.
enum _SortBy {
  name,
  manaValue,
  price,
  quantity;

  String get label => switch (this) {
        _SortBy.name => 'Name',
        _SortBy.manaValue => 'Mana value',
        _SortBy.price => 'Price',
        _SortBy.quantity => 'Quantity',
      };
}

/// A labeled, ordered section of deck cards produced by the grouping.
typedef _CardGroup = ({String label, List<DeckCard> cards});

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
  final _searchFocus = FocusNode();

  /// EDHREC-backed card recommendations for the deck's commander.
  final _edhrec = EdhrecService();
  late final _recommend = RecommendationService(_edhrec);

  /// True while an EDHREC recommendation fetch is in flight.
  bool _recommending = false;

  /// Whether the add-card search is expanded (vs. collapsed to a search icon).
  bool _searchExpanded = false;

  /// True while a Scryfall search is in flight.
  bool _loading = false;

  /// True while a CSV deck import is running.
  bool _importing = false;

  /// Deck ids whose oracle-text backfill we've already attempted this session,
  /// so opening Analyze again doesn't re-query Scryfall for genuinely-textless
  /// cards (basic lands, vanilla creatures).
  final Set<int> _detailsBackfilled = {};

  /// Last search error message, or null.
  String? _error;

  /// Raw Scryfall JSON results for the add panel.
  List<Map<String, dynamic>> _searchResults = [];

  /// Which board added cards go to (main or side); commander is set separately.
  String _addBoard = DeckBoard.main;

  /// How the mainboard is grouped into sections (defaults to card type).
  _GroupBy _groupBy = _GroupBy.type;

  /// How cards are ordered within each section (defaults to name).
  _SortBy _sortBy = _SortBy.name;

  @override
  void dispose() {
    _scryfall.dispose();
    _edhrec.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Expands the add-card search and focuses the field.
  void _openSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  /// Collapses the add-card search back to the icon, clearing stale results.
  void _closeSearch() {
    if (!_searchExpanded) return;
    _searchFocus.unfocus();
    setState(() {
      _searchExpanded = false;
      _searchResults = [];
      _error = null;
    });
  }

  /// Shorthand for the deck store this tab renders.
  DeckStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        // Phone-width screens can't fit the persistent deck list; it moves
        // into a bottom sheet opened from a picker button instead.
        final compact = MediaQuery.sizeOf(context).width < 600;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: OutlinedButton.icon(
                  onPressed: () => _showDeckSheet(context),
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: Text(store.selectedDeck?.name ?? 'Choose deck'),
                ),
              ),
              Expanded(child: _buildContent(context, compact: true)),
            ],
          );
        }
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

  /// Opens the deck list as a modal bottom sheet (compact layout only).
  void _showDeckSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: store,
          builder: (_, __) => _buildSidebar(
            ctx,
            width: null,
            onSelected: () => Navigator.pop(ctx),
          ),
        ),
      ),
    );
  }

  // ---- Sidebar -------------------------------------------------------------

  /// The left deck-list column: a "New deck" button and every deck with its
  /// card count and a rename/delete menu. Also reused as the compact layout's
  /// bottom-sheet content ([width] null to fill, [onSelected] to dismiss).
  Widget _buildSidebar(
    BuildContext context, {
    double? width = 240,
    VoidCallback? onSelected,
  }) {
    return SizedBox(
      width: width,
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
                          onTap: () {
                            store.selectDeck(deck.id);
                            onSelected?.call();
                          },
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
  Widget _buildContent(BuildContext context, {bool compact = false}) {
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
        _buildHeader(context, deck, compact: compact),
        const SizedBox(height: 12),
        _buildStats(context),
        const SizedBox(height: 12),
        _buildAddSection(context),
        const SizedBox(height: 16),
        if (store.commanders.isNotEmpty) ...[
          _sectionHeader(
              context,
              store.commanders.length > 1 ? 'Commanders' : 'Commander',
              store.commanderCount),
          for (final c in store.commanders) _deckCardRow(context, c),
          const SizedBox(height: 16),
        ],
        _sectionHeader(context, 'Mainboard', store.mainboardCount),
        if (store.mainboard.isEmpty)
          _emptyHint(context, 'No mainboard cards yet — add some above.')
        else ...[
          _buildViewControls(context),
          for (final group in _groupCards(store.mainboard)) ...[
            if (_groupBy != _GroupBy.none)
              _typeHeader(context, group.label, _sum(group.cards)),
            for (final card in group.cards) _deckCardRow(context, card),
          ],
        ],
        const SizedBox(height: 16),
        _sectionHeader(context, 'Sideboard', store.sideboardCount),
        if (store.sideboard.isEmpty)
          _emptyHint(context, 'No sideboard cards.')
        else
          for (final card in [...store.sideboard]..sort(_cardComparator))
            _deckCardRow(context, card),
      ],
    );
  }

  /// Sums the quantities of [cards] (used for the per-type header counts).
  int _sum(List<DeckCard> cards) => cards.fold(0, (s, c) => s + c.quantity);

  /// Group-by / sort-by dropdowns controlling how the mainboard is displayed.
  Widget _buildViewControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text('Group:', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 6),
          DropdownButton<_GroupBy>(
            value: _groupBy,
            isDense: true,
            items: [
              for (final g in _GroupBy.values)
                DropdownMenuItem(value: g, child: Text(g.label)),
            ],
            onChanged: (g) {
              if (g != null) setState(() => _groupBy = g);
            },
          ),
          const SizedBox(width: 20),
          Text('Sort:', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 6),
          DropdownButton<_SortBy>(
            value: _sortBy,
            isDense: true,
            items: [
              for (final s in _SortBy.values)
                DropdownMenuItem(value: s, child: Text(s.label)),
            ],
            onChanged: (s) {
              if (s != null) setState(() => _sortBy = s);
            },
          ),
        ],
      ),
    );
  }

  /// Comparator for the current sort mode; every mode breaks ties by name.
  int _cardComparator(DeckCard a, DeckCard b) {
    int byName() => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    switch (_sortBy) {
      case _SortBy.name:
        return byName();
      case _SortBy.manaValue:
        final c = a.cmc.compareTo(b.cmc);
        return c != 0 ? c : byName();
      case _SortBy.price:
        final c = (b.priceUsd ?? 0).compareTo(a.priceUsd ?? 0);
        return c != 0 ? c : byName();
      case _SortBy.quantity:
        final c = b.quantity.compareTo(a.quantity);
        return c != 0 ? c : byName();
    }
  }

  /// Splits [cards] into ordered, labeled sections per the current grouping,
  /// each internally sorted by the current sort mode. Empty sections omitted.
  List<_CardGroup> _groupCards(List<DeckCard> cards) {
    final sorted = [...cards]..sort(_cardComparator);
    switch (_groupBy) {
      case _GroupBy.none:
        return [(label: 'All', cards: sorted)];
      case _GroupBy.type:
        return [
          for (final type in CardType.values)
            if (sorted.any((c) => c.primaryType == type))
              (
                label: type.label,
                cards: sorted.where((c) => c.primaryType == type).toList(),
              ),
        ];
      case _GroupBy.color:
        return _bucketed(sorted, _colorBucketOrder, _colorBucket);
      case _GroupBy.manaValue:
        return _bucketed(sorted, _manaBucketOrder, _manaBucket);
    }
  }

  /// Buckets [sorted] by [keyOf], emitting sections in the given [order] and
  /// skipping any bucket with no cards.
  List<_CardGroup> _bucketed(
    List<DeckCard> sorted,
    List<String> order,
    String Function(DeckCard) keyOf,
  ) {
    final map = <String, List<DeckCard>>{};
    for (final c in sorted) {
      (map[keyOf(c)] ??= []).add(c);
    }
    return [
      for (final key in order)
        if (map[key] != null) (label: key, cards: map[key]!),
    ];
  }

  static const _colorBucketOrder = [
    'White',
    'Blue',
    'Black',
    'Red',
    'Green',
    'Multicolor',
    'Colorless',
  ];

  /// The color section a card belongs to (mono colors, Multicolor, Colorless).
  String _colorBucket(DeckCard c) {
    if (c.colors.isEmpty) return 'Colorless';
    if (c.colors.length > 1) return 'Multicolor';
    return switch (c.colors) {
      'W' => 'White',
      'U' => 'Blue',
      'B' => 'Black',
      'R' => 'Red',
      'G' => 'Green',
      _ => 'Colorless',
    };
  }

  static const _manaBucketOrder = [
    'MV 0',
    'MV 1',
    'MV 2',
    'MV 3',
    'MV 4',
    'MV 5',
    'MV 6',
    'MV 7+',
  ];

  /// The mana-value section a card belongs to (buckets 0..7, where 7 = 7+).
  String _manaBucket(DeckCard c) {
    final v = c.cmc >= 7 ? 7 : c.cmc.floor();
    return v == 7 ? 'MV 7+' : 'MV $v';
  }

  /// Deck name plus the CSV buttons and format dropdown. In [compact] (phone)
  /// layouts the controls wrap below the name instead of sharing its row.
  Widget _buildHeader(BuildContext context, Deck deck, {bool compact = false}) {
    final importButton = Tooltip(
      message: 'CSV columns: name, or set + collector number (required); '
          'optional quantity, foil, board (main/side/commander).',
      child: OutlinedButton.icon(
        onPressed: _importing ? null : () => _importDeckCsv(deck.id!),
        icon: const Icon(Icons.upload_file),
        label: Text(_importing ? 'Importing…' : 'Import CSV'),
      ),
    );
    final exportButton = Tooltip(
      message: 'Export this deck to a CSV the importer can read back.',
      child: OutlinedButton.icon(
        onPressed: () => _exportDeckCsv(deck),
        icon: const Icon(Icons.download),
        label: const Text('Export CSV'),
      ),
    );
    final formatControl = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(deck.name,
              style: Theme.of(context).textTheme.headlineSmall,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [importButton, exportButton, formatControl],
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Text(deck.name,
              style: Theme.of(context).textTheme.headlineSmall,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        importButton,
        const SizedBox(width: 8),
        exportButton,
        const SizedBox(width: 16),
        formatControl,
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
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _showAnalysis(context),
                  icon: const Icon(Icons.insights),
                  label: const Text('Analyze deck'),
                ),
                Tooltip(
                  message: store.commanders.isEmpty
                      ? 'Set a commander to get recommendations'
                      : 'Cards commonly played with '
                          '${store.commanderNames.join(' + ')} (EDHREC)',
                  child: OutlinedButton.icon(
                    onPressed: (store.commanders.isEmpty || _recommending)
                        ? null
                        : () => _showRecommendations(context),
                    icon: _recommending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_awesome),
                    label: const Text('Recommend cards'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Fetches EDHREC recommendations for the commander and shows them in a sheet,
  /// split into owned-only and owned-prioritized pools.
  Future<void> _showRecommendations(BuildContext context) async {
    final names = store.commanderNames;
    if (names.isEmpty) return;
    setState(() => _recommending = true);
    final deckNames =
        store.allCards.map((c) => c.name.toLowerCase()).toSet();
    RecommendationResult? result;
    String? error;
    try {
      result = await _recommend.forCommanders(
        names,
        isOwned: (nameLower) => store.ownedCount(nameLower) > 0,
        excludeNames: deckNames,
      );
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => _recommending = false);
    }
    if (!context.mounted) return;
    if (error != null) {
      _showSnack(error);
      return;
    }
    if (result == null) {
      _showSnack('EDHREC has no data for ${names.join(' + ')}.');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _RecommendationsSheet(
        result: result!,
        onAdd: _addByName,
      ),
    );
  }

  /// Resolves [name] to a printing (fuzzy, filtered to the commander's color
  /// identity when possible) and adds it to the mainboard.
  Future<void> _addByName(String name) async {
    final deckId = store.selectedDeckId;
    if (deckId == null) return;
    try {
      final json = await _scryfall.getByFuzzyName(name);
      if (json == null) {
        _showSnack('Could not find "$name" on Scryfall.');
        return;
      }
      await store.addCard(
          DeckCard.fromScryfall(json, deckId: deckId, board: DeckBoard.main));
      _showSnack('Added $name to mainboard.');
    } catch (e) {
      _showSnack(e.toString());
    }
  }

  /// Runs the offline [DeckAnalyzer] on the selected deck and shows its findings
  /// in a bottom sheet. First backfills oracle text for any rows that predate it
  /// (older decks) so ramp/draw/removal classification is accurate.
  Future<void> _showAnalysis(BuildContext context) async {
    final deckId = store.selectedDeckId;
    final needsBackfill = deckId != null &&
        !_detailsBackfilled.contains(deckId) &&
        store.allCards.any((c) => c.oracleText.isEmpty);
    if (needsBackfill) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      try {
        await store.backfillSelectedDeckDetails();
      } catch (_) {
        // Offline or Scryfall error — analyze with what we have.
      }
      _detailsBackfilled.add(deckId);
      if (context.mounted) Navigator.of(context).pop(); // dismiss spinner
    }
    if (!context.mounted) return;
    final analysis = DeckAnalyzer.analyze(
      store.mainboard,
      commanders: store.commanders,
      commanderColorIdentity: store.commanderColorIdentity,
      profile: DeckFormatProfile.forFormat(store.format),
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _DeckAnalysisSheet(analysis: analysis),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i <= 7; i++)
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Fixed-height, bottom-anchored area for the value + bar so
                // every bar rests on the same baseline regardless of height.
                SizedBox(
                  height: 64,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('${curve[i] ?? 0}',
                          style: Theme.of(context).textTheme.labelSmall),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        height: max == 0 ? 2 : 4 + 44 * (curve[i] ?? 0) / max,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(i == 7 ? '7+' : '$i',
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
      ],
    );
  }

  // ---- Add panel -----------------------------------------------------------

  /// The add-card area: a magnifying-glass button when collapsed, or the full
  /// search panel when expanded. The expanded panel collapses when the user
  /// taps outside it (taps on the results or toggle keep it open).
  Widget _buildAddSection(BuildContext context) {
    if (!_searchExpanded) {
      return Align(
        alignment: Alignment.centerLeft,
        child: IconButton.filledTonal(
          tooltip: 'Add cards — search by name',
          icon: const Icon(Icons.search),
          onPressed: _openSearch,
        ),
      );
    }
    return TapRegion(
      onTapOutside: (_) => _closeSearch(),
      child: _buildAddPanel(context),
    );
  }

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
                    focusNode: _searchFocus,
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

  /// Prompts for a CSV file, imports its rows into the deck with [deckId] via
  /// [DeckCsvImportService], reloads the store, and shows a summary dialog.
  Future<void> _importDeckCsv(int deckId) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
      dialogTitle: 'Choose a deck CSV to import',
    );
    if (picked == null || picked.files.isEmpty) return; // cancelled

    final bytes = picked.files.single.bytes;
    if (bytes == null) {
      _showSnack('Could not read the selected file.');
      return;
    }

    setState(() => _importing = true);
    try {
      final service =
          DeckCsvImportService(DatabaseService.instance, _scryfall);
      final result = await service.importFromBytes(bytes, deckId: deckId);
      await store.load();
      if (mounted) _showDeckImportSummary(result);
    } catch (e) {
      if (mounted) _showSnack('Import failed: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Shows the post-import dialog: how many cards were added, rows skipped, and
  /// the identifiers Scryfall couldn't match.
  void _showDeckImportSummary(DeckCsvImportResult result) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deck CSV import complete'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Added ${result.copies} '
                  'card${result.copies == 1 ? '' : 's'} '
                  '(${result.imported} '
                  'entr${result.imported == 1 ? 'y' : 'ies'}) to this deck.'),
              if (result.skipped > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${result.skipped} row${result.skipped == 1 ? '' : 's'} '
                    'skipped (no card identifier).',
                  ),
                ),
              if (result.notFound.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  "Couldn't match ${result.notFound.length} on Scryfall:",
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(result.notFound.join('\n')),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// Exports [deck]'s cards to a CSV file the deck importer can read back.
  Future<void> _exportDeckCsv(Deck deck) async {
    final cards = store.allCards;
    if (cards.isEmpty) {
      _showSnack('This deck has no cards to export.');
      return;
    }
    final csv = DeckCsvExportService.standard(cards);

    // A filesystem-safe default filename derived from the deck name.
    final safeName = deck.name.trim().isEmpty
        ? 'deck'
        : deck.name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export deck',
      fileName: '$safeName.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (path == null) return; // cancelled
    final finalPath = path.toLowerCase().endsWith('.csv') ? path : '$path.csv';

    try {
      await File(finalPath).writeAsString(csv);
      _showSnack('Exported ${cards.length} cards to $finalPath');
    } catch (e) {
      _showSnack('Export failed: $e');
    }
  }

  /// Shows a brief SnackBar message.
  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

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

/// Bottom sheet rendering a [DeckAnalysis]: a compact stat readout on top and
/// the ranked findings (warnings first) below.
class _DeckAnalysisSheet extends StatelessWidget {
  const _DeckAnalysisSheet({required this.analysis});

  final DeckAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Deck analysis',
              style: Theme.of(context).textTheme.titleLarge),
          Text('${a.profile.name} · ${a.totalCards} cards',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _metric(context, 'Lands', '${a.landCount} / ~${a.recommendedLands}'),
              _metric(context, 'Ramp', '${a.rampCount}'),
              _metric(context, 'Draw', '${a.drawCount}'),
              _metric(context, 'Removal', '${a.removalCount}'),
              _metric(context, 'Wipes', '${a.wipeCount}'),
              if (a.cheatCount > 0) _metric(context, 'Cheat', '${a.cheatCount}'),
              if (a.recursionCount > 0)
                _metric(context, 'Recursion', '${a.recursionCount}'),
              _metric(context, 'Avg MV', a.avgManaValue.toStringAsFixed(1)),
            ],
          ),
          const Divider(height: 24),
          if (a.findings.isEmpty)
            const Text('No issues found.')
          else
            for (final f in a.findings) _finding(context, f),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      );

  Widget _finding(BuildContext context, DeckFinding f) {
    final (icon, color) = switch (f.severity) {
      FindingSeverity.warning => (Icons.error_outline, Colors.redAccent),
      FindingSeverity.suggestion => (Icons.lightbulb_outline, Colors.amber),
      FindingSeverity.info => (Icons.check_circle_outline, Colors.green),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f.message),
                if (f.cards.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      f.cards.take(12).join(', ') +
                          (f.cards.length > 12
                              ? ' +${f.cards.length - 12} more'
                              : ''),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet listing EDHREC recommendations for a commander, with a toggle
/// between the owned-only pool and the owned-prioritized "all" pool. Each row
/// can be added to the deck; added rows disable to avoid duplicates.
class _RecommendationsSheet extends StatefulWidget {
  const _RecommendationsSheet({required this.result, required this.onAdd});

  final RecommendationResult result;
  final Future<void> Function(String name) onAdd;

  @override
  State<_RecommendationsSheet> createState() => _RecommendationsSheetState();
}

class _RecommendationsSheetState extends State<_RecommendationsSheet> {
  /// True = owned-only pool (A); false = all/owned-first pool (B).
  bool _ownedOnly = false;

  /// Names already added from this sheet, so their button disables.
  final Set<String> _added = {};

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final cards = _ownedOnly ? r.ownedOnly : r.all;
    final ownedCount = r.ownedOnly.length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Recommended for ${r.commanderName}',
                    style: Theme.of(context).textTheme.titleLarge),
                Text('Cards commonly played with this commander (EDHREC)',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                        value: false,
                        label: Text('All (${r.all.length})'),
                        icon: const Icon(Icons.public)),
                    ButtonSegment(
                        value: true,
                        label: Text('Owned ($ownedCount)'),
                        icon: const Icon(Icons.inventory_2_outlined)),
                  ],
                  selected: {_ownedOnly},
                  onSelectionChanged: (s) =>
                      setState(() => _ownedOnly = s.first),
                ),
              ],
            ),
          ),
          Expanded(
            child: cards.isEmpty
                ? Center(
                    child: Text(_ownedOnly
                        ? 'You don\'t own any of the top recommendations yet.'
                        : 'No recommendations.'),
                  )
                : ListView.builder(
                    controller: controller,
                    itemCount: cards.length,
                    itemBuilder: (context, i) => _row(context, cards[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, CardRecommendation c) {
    final pct = (c.inclusion * 100).round();
    final added = _added.contains(c.name.toLowerCase());
    return ListTile(
      dense: true,
      title: Text(c.name),
      subtitle: Text('${c.category} · $pct% of decks'),
      leading: c.owned
          ? const Tooltip(
              message: 'In your collection',
              child: Icon(Icons.check_circle, color: Colors.green, size: 20))
          : Icon(Icons.circle_outlined,
              color: Theme.of(context).disabledColor, size: 20),
      trailing: added
          ? const Icon(Icons.check, color: Colors.green)
          : IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Add to mainboard',
              onPressed: () async {
                setState(() => _added.add(c.name.toLowerCase()));
                await widget.onAdd(c.name);
              },
            ),
    );
  }
}
