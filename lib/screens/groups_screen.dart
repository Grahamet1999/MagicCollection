import 'dart:async';

import 'package:flutter/material.dart';

import '../models/group.dart';
import '../models/group_card.dart';
import '../services/auth_service.dart';
import '../services/collection_store.dart';
import '../services/database_service.dart';
import '../services/group_service.dart';
import '../widgets/card_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/tags.dart';

/// The shared "group binder": create/join groups, publish your local collection,
/// and browse everyone's pooled cards live (who owns what, with trade tags).
class GroupsScreen extends StatefulWidget {
  const GroupsScreen({
    super.key,
    required this.auth,
    required this.groups,
    required this.store,
  });

  final AuthService auth;
  final GroupService groups;
  final CollectionStore store;

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  /// Groups the signed-in user belongs to.
  List<Group> _myGroups = [];

  /// The group currently being viewed.
  Group? _selected;

  /// Live subscription to the selected group's pooled cards (RTDB SSE).
  StreamSubscription<List<GroupCard>>? _sub;

  /// Latest pooled cards from [_sub], flattened across all members.
  List<GroupCard> _binder = [];

  bool _loading = true;
  bool _publishing = false;
  String? _error;

  // Binder view filters.
  String _search = '';
  String _ownerFilter = ''; // '' = everyone
  final Set<String> _tagFilter = {};

  /// The signed-in user's uid (only used while this screen is shown, so the
  /// user is guaranteed non-null).
  String get _uid => widget.auth.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Fetches the user's groups and auto-selects the first one. Called on load
  /// and after create/join/leave/delete to refresh the list.
  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final groups = await widget.groups.myGroups();
      setState(() {
        _myGroups = groups;
        _loading = false;
      });
      if (groups.isNotEmpty) _select(groups.first);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Selects [group] to view: cancels any prior subscription and opens a fresh
  /// live stream of its pooled cards into [_binder].
  void _select(Group group) {
    _sub?.cancel();
    setState(() {
      _selected = group;
      _binder = [];
      _error = null;
    });
    _sub = widget.groups.streamGroupCards(group).listen(
      (cards) => setState(() => _binder = cards),
      onError: (Object e) => setState(() => _error = e.toString()),
    );
  }

  /// Prompts for a name, creates a group, and selects it.
  Future<void> _createGroup() async {
    final name = await promptForName(context,
        title: 'New group', label: 'Group name');
    if (name == null || name.isEmpty) return;
    await _guard(() async {
      final g = await widget.groups.createGroup(name);
      await _loadGroups();
      _select(g);
    });
  }

  /// Prompts for an invite code, joins the group, and selects it.
  Future<void> _joinGroup() async {
    final code = await promptForName(context,
        title: 'Join group', label: 'Invite code');
    if (code == null || code.isEmpty) return;
    await _guard(() async {
      final g = await widget.groups.joinGroup(code);
      await _loadGroups();
      _select(g);
    });
  }

  /// Leaves [group] after confirmation (removes your published cards but not
  /// the group), then refreshes the list.
  Future<void> _leaveGroup(Group group) async {
    final ok = await _confirm(
      'Leave "${group.name}"?',
      'Your published cards are removed from this group. Your local '
          'collection is unaffected.',
    );
    if (!ok) return;
    await _sub?.cancel();
    await _guard(() => widget.groups.leaveGroup(group));
    setState(() => _selected = null);
    await _loadGroups();
  }

  /// Deletes [group] entirely (owner-only) after confirmation, then refreshes
  /// the list. See [GroupService.deleteGroup] for the resilient delete flow.
  Future<void> _deleteGroup(Group group) async {
    final ok = await _confirm(
      'Delete "${group.name}"?',
      'This deletes the group for everyone and removes all pooled cards. It '
          'cannot be undone. (Your local collection is unaffected.)',
    );
    if (!ok) return;
    await _sub?.cancel();
    await _guard(() => widget.groups.deleteGroup(group));
    setState(() => _selected = null);
    await _loadGroups();
  }

  /// Shows a generic yes/no confirmation dialog with a destructive-colored
  /// Confirm button. Returns true only if the user confirms.
  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  /// Publishes a snapshot of the entire local collection to the selected group
  /// (the "Sync my collection" action), reporting the result via a SnackBar.
  Future<void> _publish() async {
    if (_selected == null) return;
    setState(() => _publishing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final cards = await DatabaseService.instance.getCards();
      await widget.groups.publishCollection(_selected!.id, cards);
      messenger.showSnackBar(SnackBar(
          content: Text('Published ${cards.length} cards to '
              '"${_selected!.name}".')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Publish failed: $e')));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  /// Removes all of your published copies of [group]'s card from the binder
  /// (after confirmation); your local collection is untouched.
  Future<void> _removeMine(_CardGroup group) async {
    final hold = group.owners[_uid];
    if (hold == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove your ${group.name}?'),
        content: const Text('Removes your copies from this group binder. Your '
            'local collection is unaffected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _guard(() async {
      for (final key in hold.keys) {
        await widget.groups.removeMyCard(_selected!.id, key);
      }
    });
  }

  /// Runs [action], surfacing any error as a SnackBar instead of letting it
  /// escape — the common error handler for the mutating actions above.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  /// Groups the pooled cards by card name — one row per card, with each owner's
  /// total quantity — then applies the search and owner filters.
  List<_CardGroup> get _grouped {
    final q = _search.trim().toLowerCase();
    final map = <String, _CardGroup>{};
    for (final c in _binder) {
      final g = map.putIfAbsent(
          c.name.toLowerCase(), () => _CardGroup(name: c.name));
      g.imageUrl ??= c.imageUrl;
      final hold = g.owners
          .putIfAbsent(c.ownerUid, () => _OwnerHold(name: c.ownerName));
      hold.qty += c.quantity;
      hold.keys.add(c.key);
      hold.tags.addAll(c.tags);
    }
    var groups = map.values.toList();
    if (q.isNotEmpty) {
      groups = groups
          .where((g) =>
              g.name.toLowerCase().contains(q) ||
              g.owners.values.any((o) =>
                  o.tags.any((t) => t.toLowerCase().contains(q))))
          .toList();
    }
    // A card is shown if at least one owner passes both the owner and tag
    // filters (e.g. owner = Bob AND tag = Trade → cards Bob tagged Trade).
    if (_ownerFilter.isNotEmpty || _tagFilter.isNotEmpty) {
      groups = groups.where((g) {
        return g.owners.entries.any((e) {
          final ownerOk = _ownerFilter.isEmpty || e.key == _ownerFilter;
          final tagOk =
              _tagFilter.isEmpty || e.value.tags.any(_tagFilter.contains);
          return ownerOk && tagOk;
        });
      }).toList();
    }
    groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return groups;
  }

  /// All tags currently present in the binder (for the tag filter menu).
  List<String> get _allTags {
    final set = <String>{...kTradeTags};
    for (final c in _binder) {
      set.addAll(c.tags);
    }
    return set.toList()..sort();
  }

  /// Edits the trade tags on your copies of [group]'s card — updates both your
  /// local collection (source of truth) and your published group cards.
  Future<void> _editMyTags(_CardGroup group) async {
    final hold = group.owners[_uid];
    if (hold == null) return;
    final result = await showTagEditor(context, hold.tags.toList());
    if (result == null) return;
    await _guard(() async {
      // Local collection: tag every local card with this name.
      final local = await DatabaseService.instance.getCards();
      for (final c in local) {
        if (c.name.toLowerCase() == group.name.toLowerCase()) {
          await DatabaseService.instance.setCardTags(c.id!, result);
        }
      }
      // Group: update each of my published nodes for this card.
      for (final key in hold.keys) {
        await widget.groups.setMyCardTags(_selected!.id, key, result);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
        actions: [
          IconButton(
            tooltip: 'Join group',
            icon: const Icon(Icons.group_add),
            onPressed: _joinGroup,
          ),
          IconButton(
            tooltip: 'New group',
            icon: const Icon(Icons.add),
            onPressed: _createGroup,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _myGroups.isEmpty
              ? _emptyState(context)
              : _buildBody(context),
    );
  }

  /// Shown when the user belongs to no groups: create/join call-to-action.
  Widget _emptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("You're not in any groups yet."),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _createGroup,
                icon: const Icon(Icons.add),
                label: const Text('Create a group'),
              ),
              OutlinedButton.icon(
                onPressed: _joinGroup,
                icon: const Icon(Icons.group_add),
                label: const Text('Join with a code'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The main layout: group picker + invite/members/options row, the
  /// search/owner/tag filter row, and the live binder list.
  Widget _buildBody(BuildContext context) {
    final group = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              DropdownButton<Group>(
                value: group,
                items: [
                  for (final g in _myGroups)
                    DropdownMenuItem(value: g, child: Text(g.name)),
                ],
                onChanged: (g) {
                  if (g != null) _select(g);
                },
              ),
              const SizedBox(width: 16),
              if (group != null) ...[
                Chip(
                  avatar: const Icon(Icons.key, size: 16),
                  label: Text('Invite: ${group.inviteCode}'),
                ),
                const SizedBox(width: 8),
                Text('${group.members.length} member'
                    '${group.members.length == 1 ? '' : 's'}'),
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: 'Group options',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    if (v == 'leave') _leaveGroup(group);
                    if (v == 'delete') _deleteGroup(group);
                  },
                  itemBuilder: (_) => [
                    if (group.ownerUid == _uid)
                      const PopupMenuItem(
                          value: 'delete', child: Text('Delete group'))
                    else
                      const PopupMenuItem(
                          value: 'leave', child: Text('Leave group')),
                  ],
                ),
              ],
              const Spacer(),
              FilledButton.icon(
                onPressed: _publishing ? null : _publish,
                icon: const Icon(Icons.cloud_upload),
                label: Text(_publishing
                    ? 'Publishing…'
                    : 'Sync my collection to this group'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search the group binder…',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: 12),
              if (group != null)
                DropdownButton<String>(
                  value: _ownerFilter,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Everyone')),
                    for (final m in group.members)
                      DropdownMenuItem(
                          value: m.uid, child: Text(m.displayName)),
                  ],
                  onChanged: (v) => setState(() => _ownerFilter = v ?? ''),
                ),
              const SizedBox(width: 8),
              _buildTagFilter(context),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(child: _buildBinder(context)),
      ],
    );
  }

  /// The scrollable binder: one row per card, each listing every owner's
  /// holdings. Shows an appropriate empty message when nothing is present or
  /// nothing matches the filters.
  Widget _buildBinder(BuildContext context) {
    final groups = _grouped;
    if (groups.isEmpty) {
      return Center(
        child: Text(
          _binder.isEmpty
              ? 'No cards published yet. Hit "Sync my collection" above.'
              : 'No cards match your search.',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return ListView.separated(
      itemCount: groups.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final g = groups[i];
        // Owners sorted with you first, then by name.
        final owners = g.owners.entries.toList()
          ..sort((a, b) {
            if (a.key == _uid) return -1;
            if (b.key == _uid) return 1;
            return a.value.name.toLowerCase().compareTo(b.value.name.toLowerCase());
          });
        return ListTile(
          leading: CardImage(url: g.imageUrl, width: 36, height: 50),
          title: Text(g.name),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final e in owners) _ownerBlock(context, g, e.key, e.value),
              ],
            ),
          ),
        );
      },
    );
  }

  /// One owner's holdings for a card: their name ×qty, their tags shown inline,
  /// and (for your own) inline edit-tags and remove controls.
  Widget _ownerBlock(
    BuildContext context,
    _CardGroup group,
    String uid,
    _OwnerHold hold,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final mine = uid == _uid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person, size: 14),
          const SizedBox(width: 4),
          Text('${hold.name} ×${hold.qty}',
              style: const TextStyle(fontWeight: FontWeight.w500)),
          for (final t in hold.tags) ...[
            const SizedBox(width: 4),
            tagChip(t),
          ],
          if (mine) ...[
            const SizedBox(width: 6),
            InkWell(
              onTap: () => _editMyTags(group),
              customBorder: const CircleBorder(),
              child: Tooltip(
                message: 'Edit my tags',
                child: Icon(Icons.sell_outlined, size: 16, color: scheme.primary),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => _removeMine(group),
              customBorder: const CircleBorder(),
              child: const Tooltip(
                message: 'Remove my copies',
                child: Icon(Icons.close, size: 16),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The tag-filter dropdown: toggling a tag adds/removes it from [_tagFilter];
  /// "Clear filter" empties the set.
  Widget _buildTagFilter(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Filter by tag',
      onSelected: (tag) {
        setState(() {
          if (tag.isEmpty) {
            _tagFilter.clear();
          } else if (!_tagFilter.remove(tag)) {
            _tagFilter.add(tag);
          }
        });
      },
      itemBuilder: (_) => [
        for (final t in _allTags)
          CheckedPopupMenuItem(
            value: t,
            checked: _tagFilter.contains(t),
            child: Text(t),
          ),
        if (_tagFilter.isNotEmpty)
          const PopupMenuItem(value: '', child: Text('Clear filter')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sell_outlined,
                size: 18,
                color: _tagFilter.isEmpty
                    ? null
                    : Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(_tagFilter.isEmpty ? 'Tags' : 'Tags (${_tagFilter.length})'),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

/// One card (by name) in the grouped binder, with each owner's holdings keyed
/// by owner uid.
class _CardGroup {
  _CardGroup({required this.name});

  /// Display name of the card.
  final String name;

  /// First image seen for this card, used as the row thumbnail.
  String? imageUrl;

  /// Owner uid → their holdings of this card.
  final Map<String, _OwnerHold> owners = {};
}

/// One owner's holdings of a single card within the binder.
class _OwnerHold {
  _OwnerHold({required this.name});

  /// Owner's display name.
  final String name;

  /// Total copies this owner has published (summed across printings).
  int qty = 0;

  /// RTDB card keys backing this holding, needed to edit/remove the entries.
  final List<String> keys = [];

  /// Union of trade tags across this owner's copies.
  final Set<String> tags = {};
}
