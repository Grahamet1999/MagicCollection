/// A member of a group (household).
class GroupMember {
  GroupMember({required this.uid, required this.displayName, required this.role});

  /// Firebase Auth user id of the member.
  final String uid;

  /// Name shown in the group binder UI.
  final String displayName;

  /// Either `'owner'` or `'member'`; only the owner may delete the group.
  final String role; // 'owner' | 'member'

  /// Whether this member created (and can delete) the group.
  bool get isOwner => role == 'owner';
}

/// A shared group: a set of friends/family who pool their collections into a
/// browsable "group binder" for trading.
class Group {
  Group({
    required this.id,
    required this.name,
    required this.ownerUid,
    required this.inviteCode,
    required this.members,
  });

  /// Realtime Database push id of the group (its key under `groups/`).
  final String id;

  /// User-visible group name.
  final String name;

  /// Auth uid of the owner; mirrored into the RTDB rules to gate deletes.
  final String ownerUid;

  /// Short code a friend types to join the group.
  final String inviteCode;

  /// Everyone currently in the group.
  final List<GroupMember> members;

  /// Builds a [Group] from its RTDB node ([json]) and its key ([id]).
  ///
  /// Every field is defensively defaulted because the cloud data is untrusted
  /// and older records may be missing keys.
  factory Group.fromRtdb(String id, Map<String, dynamic> json) {
    final membersJson = (json['members'] as Map<String, dynamic>?) ?? {};
    return Group(
      id: id,
      name: json['name'] as String? ?? 'Group',
      ownerUid: json['ownerUid'] as String? ?? '',
      inviteCode: json['inviteCode'] as String? ?? '',
      members: membersJson.entries
          .map((e) => GroupMember(
                uid: e.key,
                displayName:
                    (e.value as Map)['displayName'] as String? ?? 'Member',
                role: (e.value as Map)['role'] as String? ?? 'member',
              ))
          .toList(),
    );
  }
}
