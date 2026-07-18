/// A member of a group (household).
class GroupMember {
  GroupMember({required this.uid, required this.displayName, required this.role});

  final String uid;
  final String displayName;
  final String role; // 'owner' | 'member'

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

  final String id;
  final String name;
  final String ownerUid;
  final String inviteCode;
  final List<GroupMember> members;

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
