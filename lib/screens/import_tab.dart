import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mtg_card.dart';
import '../services/collection_store.dart';
import '../services/csv_import_service.dart';
import '../services/database_service.dart';
import '../services/scryfall_service.dart';
import '../widgets/card_image.dart';

/// Import tab: look up cards on Scryfall two ways — by exact printing
/// (set code + collector number) or by name search — and add them to the
/// local collection.
class ImportTab extends StatefulWidget {
  const ImportTab({super.key, required this.store});

  final CollectionStore store;

  @override
  State<ImportTab> createState() => _ImportTabState();
}

/// The two lookup modes: exact printing vs. name search.
enum _Mode { setNumber, name }

class _ImportTabState extends State<ImportTab> {
  /// Scryfall client owned by this tab (disposed with it).
  final _scryfall = ScryfallService();

  /// Active lookup mode.
  _Mode _mode = _Mode.setNumber;

  // Text controllers backing the entry fields.
  final _setController = TextEditingController();
  final _numberController = TextEditingController();
  final _quantityController = TextEditingController(text: '1');
  final _nameController = TextEditingController();

  // Focus nodes used to chain keyboard entry (set → number → quantity).
  final _setFocus = FocusNode();
  final _numberFocus = FocusNode();
  final _quantityFocus = FocusNode();

  /// True while a Scryfall lookup/search is in flight.
  bool _loading = false;

  /// True while a CSV import is running.
  bool _importing = false;

  /// Last error message to show, or null.
  String? _error;

  /// Results of a name search (multiple printings to choose from).
  List<Map<String, dynamic>> _searchResults = [];

  /// The currently selected/looked-up printing, ready to be added.
  Map<String, dynamic>? _selected;

  /// The most recently added card, shown so it's easy to confirm what was last
  /// imported after stepping away.
  _LastAdded? _lastAdded;

  @override
  void dispose() {
    _scryfall.dispose();
    _setController.dispose();
    _numberController.dispose();
    _quantityController.dispose();
    _nameController.dispose();
    _setFocus.dispose();
    _numberFocus.dispose();
    _quantityFocus.dispose();
    super.dispose();
  }

  /// Looks up the exact printing and shows it in the add panel (without adding),
  /// so foil/quantity can be chosen before committing. Compare
  /// [_quickAddBySetNumber], which adds immediately.
  Future<void> _lookupBySetNumber() async {
    final set = _setController.text.trim();
    final number = _numberController.text.trim();
    if (set.isEmpty || number.isEmpty) {
      setState(() => _error = 'Enter both a set code and a collector number.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
      _searchResults = [];
    });
    try {
      final card = await _scryfall.getBySetAndNumber(set, number);
      setState(() {
        if (card == null) {
          _error = 'No card found for $set #$number.';
        } else {
          _selected = card;
        }
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Looks up the exact printing and adds it straight to the collection
  /// (non-foil, using the quantity field). Used for rapid keyboard entry:
  /// set → Tab → number → Tab → quantity → Enter. Keeps the set code, resets
  /// quantity to 1, and refocuses the number field so several cards from the
  /// same set can be entered in a row.
  Future<void> _quickAddBySetNumber() async {
    final set = _setController.text.trim();
    final number = _numberController.text.trim();
    if (set.isEmpty || number.isEmpty) {
      setState(() => _error = 'Enter both a set code and a collector number.');
      return;
    }
    final parsedQty = int.tryParse(_quantityController.text.trim());
    final quantity = (parsedQty == null || parsedQty < 1) ? 1 : parsedQty;

    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
      _searchResults = [];
    });
    try {
      final card = await _scryfall.getBySetAndNumber(set, number);
      if (card == null) {
        setState(() => _error = 'No card found for $set #$number.');
      } else {
        await _addCard(MtgCard.fromScryfall(card, quantity: quantity));
        // Keep the set for the next card; reset number + quantity and refocus.
        _numberController.clear();
        _quantityController.text = '1';
        _numberFocus.requestFocus();
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Searches Scryfall by name and shows the matching printings to choose from.
  Future<void> _searchByName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a card name to search.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
      _searchResults = [];
    });
    try {
      final results = await _scryfall.searchByName(name);
      setState(() {
        _searchResults = results;
        if (results.isEmpty) _error = 'No printings matched "$name".';
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Adds [card] to the collection (merging into a matching entry), records it
  /// as the "last added" card, and shows a confirming SnackBar.
  Future<void> _addCard(MtgCard card) async {
    final result = await widget.store.addCard(card);
    if (!mounted) return;
    setState(() {
      _lastAdded = _LastAdded(
        card: card,
        merged: result.merged,
        totalQuantity: result.quantity,
      );
    });
    final label = '${card.name} (${card.setCode} #${card.collectorNumber})'
        '${card.foil ? ' • Foil' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.merged
              ? 'Updated $label — now ${result.quantity} in your collection.'
              : 'Added ${card.quantity}× $label to your collection.',
        ),
      ),
    );
  }

  /// Prompts for a CSV file, imports it via [CsvImportService], reloads the
  /// collection, and shows a summary dialog.
  Future<void> _importCsv() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
      dialogTitle: 'Choose a CSV to import',
    );
    if (picked == null || picked.files.isEmpty) return; // cancelled

    final bytes = picked.files.single.bytes;
    if (bytes == null) {
      setState(() => _error = 'Could not read the selected file.');
      return;
    }

    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final service = CsvImportService(DatabaseService.instance, _scryfall);
      final result = await service.importFromBytes(bytes);
      await widget.store.load();
      if (mounted) _showImportSummary(result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Shows the post-import dialog: counts of imported/skipped rows and the list
  /// of identifiers Scryfall couldn't match.
  void _showImportSummary(CsvImportResult result) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('CSV import complete'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Imported ${result.imported} card'
                  '${result.imported == 1 ? '' : 's'} into your collection.'),
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<_Mode>(
                  segments: const [
                    ButtonSegment(
                      value: _Mode.setNumber,
                      label: Text('Set + Collector #'),
                      icon: Icon(Icons.tag),
                    ),
                    ButtonSegment(
                      value: _Mode.name,
                      label: Text('Name search'),
                      icon: Icon(Icons.search),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) {
                    setState(() {
                      _mode = s.first;
                      _error = null;
                      _selected = null;
                      _searchResults = [];
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: 'CSV columns: name, or set + collector number '
                    '(required); optional quantity, foil, folder.',
                child: OutlinedButton.icon(
                  onPressed: _importing ? null : _importCsv,
                  icon: const Icon(Icons.upload_file),
                  label: Text(_importing ? 'Importing…' : 'Import from CSV'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_mode == _Mode.setNumber)
            _buildSetNumberForm()
          else
            _buildNameForm(),
          const SizedBox(height: 12),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_loading || _importing) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  /// The set-code + collector-number + quantity entry row, wired for fast
  /// keyboard entry (Enter chains fields, then adds).
  Widget _buildSetNumberForm() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: TextField(
            controller: _setController,
            focusNode: _setFocus,
            decoration: const InputDecoration(
              labelText: 'Set code',
              hintText: 'e.g. MH3',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
            // Enter in the set field jumps to the collector number field.
            onSubmitted: (_) => _numberFocus.requestFocus(),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 170,
          child: TextField(
            controller: _numberController,
            focusNode: _numberFocus,
            decoration: const InputDecoration(
              labelText: 'Collector number',
              hintText: 'e.g. 234',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
            // Enter adds straight away (quantity defaults to 1).
            onSubmitted: (_) => _loading ? null : _quickAddBySetNumber(),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 90,
          child: TextField(
            controller: _quantityController,
            focusNode: _quantityFocus,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Qty',
              border: OutlineInputBorder(),
            ),
            // Enter after setting a quantity adds the card.
            onSubmitted: (_) => _loading ? null : _quickAddBySetNumber(),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _loading ? null : _quickAddBySetNumber,
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _loading ? null : _lookupBySetNumber,
          icon: const Icon(Icons.search),
          label: const Text('Look up'),
        ),
      ],
    );
  }

  /// The card-name search row.
  Widget _buildNameForm() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Card name',
              hintText: 'e.g. Lightning Bolt',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _searchByName(),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _loading ? null : _searchByName,
          icon: const Icon(Icons.search),
          label: const Text('Search'),
        ),
      ],
    );
  }

  /// The lower results area, whose content depends on state: the add panel for
  /// a chosen printing, the name-search result list, the last-added card, or an
  /// idle hint.
  Widget _buildResults() {
    // A single looked-up/selected printing ready to add.
    if (_selected != null) {
      return SingleChildScrollView(
        child: _AddCardPanel(
          json: _selected!,
          onAdd: _addCard,
          onBack: _searchResults.isEmpty
              ? null
              : () => setState(() => _selected = null),
        ),
      );
    }

    // Multiple printings from a name search; pick one.
    if (_searchResults.isNotEmpty) {
      return ListView.separated(
        itemCount: _searchResults.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final json = _searchResults[i];
          final set = (json['set'] as String? ?? '').toUpperCase();
          final number = json['collector_number'] as String? ?? '';
          final priceMap = json['prices'] as Map<String, dynamic>?;
          final usd = priceMap?['usd'] ?? priceMap?['usd_foil'];
          return ListTile(
            leading: CardImage(
              url: MtgCard.fromScryfall(json).imageUrl,
              width: 46,
              height: 64,
            ),
            title: Text(json['name'] as String? ?? 'Unknown'),
            subtitle: Text(
              '${json['set_name'] ?? set} • $set #$number'
              '${usd != null ? ' • \$$usd' : ''}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _selected = json),
          );
        },
      );
    }

    // Idle: show the last card added (handy after stepping away), or a hint.
    if (_lastAdded != null) {
      return SingleChildScrollView(child: _buildLastAdded(_lastAdded!));
    }

    return Center(
      child: Text(
        'Look up a card to add it to your collection.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
      ),
    );
  }

  /// The "Last added" confirmation card (large image + printing + how the add
  /// affected the collection).
  Widget _buildLastAdded(_LastAdded last) {
    final card = last.card;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CardImage(url: card.imageUrl, width: 200, height: 280),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.check_circle, color: scheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'LAST ADDED',
                        style: Theme.of(context)
                            .textTheme
                            .labelLarge
                            ?.copyWith(
                              color: scheme.primary,
                              letterSpacing: 1.2,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    card.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${card.setCode} #${card.collectorNumber}'
                    '${card.foil ? ' • Foil' : ''}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (card.priceUsd != null) ...[
                    const SizedBox(height: 4),
                    Text('\$${card.priceUsd!.toStringAsFixed(2)} USD'),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    last.merged
                        ? 'Added ${card.quantity} — now ${last.totalQuantity} '
                            'in your collection.'
                        : 'Added ${card.quantity} to your collection.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.outline,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Snapshot of the most recently added card for the "Last added" panel.
class _LastAdded {
  _LastAdded({
    required this.card,
    required this.merged,
    required this.totalQuantity,
  });

  /// The card that was added.
  final MtgCard card;

  /// True if it merged into an existing entry rather than creating a new one.
  final bool merged;

  /// Resulting total quantity of the affected entry.
  final int totalQuantity;
}

/// Panel showing one printing with foil + quantity controls and an Add button.
class _AddCardPanel extends StatefulWidget {
  const _AddCardPanel({required this.json, required this.onAdd, this.onBack});

  /// Raw Scryfall JSON for the printing being previewed.
  final Map<String, dynamic> json;

  /// Called with the fully-built card when the user taps Add.
  final Future<void> Function(MtgCard) onAdd;

  /// Optional "back to results" callback (null in single-lookup mode).
  final VoidCallback? onBack;

  @override
  State<_AddCardPanel> createState() => _AddCardPanelState();
}

class _AddCardPanelState extends State<_AddCardPanel> {
  bool _foil = false;
  int _quantity = 1;
  bool _adding = false;

  /// Whether this printing has a foil finish available (has a foil price or is
  /// flagged foil), which gates the Foil toggle.
  bool get _hasFoil {
    final prices = widget.json['prices'] as Map<String, dynamic>?;
    return prices?['usd_foil'] != null ||
        (widget.json['foil'] as bool? ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final json = widget.json;
    final preview = MtgCard.fromScryfall(json, foil: _foil, quantity: _quantity);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CardImage(url: preview.imageUrl, width: 200, height: 280),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.onBack != null)
                    TextButton.icon(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Back to results'),
                    ),
                  Text(
                    preview.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${json['set_name'] ?? preview.setCode} • '
                    '${preview.setCode} #${preview.collectorNumber}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (preview.priceUsd != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '\$${preview.priceUsd!.toStringAsFixed(2)} USD'
                      '${_foil ? ' (foil)' : ''}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Quantity:'),
                      IconButton(
                        onPressed: _quantity > 1
                            ? () => setState(() => _quantity--)
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text(
                        '$_quantity',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      IconButton(
                        onPressed: () => setState(() => _quantity++),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  FilterChip(
                    label: const Text('Foil'),
                    avatar: const Icon(Icons.auto_awesome, size: 18),
                    selected: _foil,
                    onSelected: _hasFoil
                        ? (v) => setState(() => _foil = v)
                        : null,
                  ),
                  if (!_hasFoil)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'No foil printing available.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _adding
                        ? null
                        : () async {
                            setState(() => _adding = true);
                            await widget.onAdd(preview);
                            if (mounted) setState(() => _adding = false);
                          },
                    icon: const Icon(Icons.add),
                    label: const Text('Add to collection'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
