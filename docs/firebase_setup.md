# Cloud "Group Binder" — Firebase setup

The Groups feature (shared collections for trading) uses **Firebase Auth** (email/
password) and the **Realtime Database**, accessed purely over their REST/SSE APIs — no
FlutterFire plugins, so it works on Windows desktop. Until you complete this setup the
Groups feature is hidden and the rest of the app works normally on local storage.

## 1. Create the Firebase project
1. Go to <https://console.firebase.google.com> and **Add project**.
2. In **Build → Authentication → Sign-in method**, enable **Email/Password**.
3. In **Build → Realtime Database**, **Create database** (start in *locked mode*; rules
   below replace the defaults).

## 2. Paste the security rules
In **Realtime Database → Rules**, paste this and **Publish**:

```json
{
  "rules": {
    "users": {
      "$uid": {
        ".read": "auth != null && auth.uid === $uid",
        ".write": "auth != null && auth.uid === $uid"
      }
    },
    "invites": {
      ".read": "auth != null",
      "$code": { ".write": "auth != null" }
    },
    "groups": {
      "$gid": {
        ".read": "auth != null && data.child('members').child(auth.uid).exists()",
        ".write": "auth != null && (!data.exists() || data.child('ownerUid').val() === auth.uid || (!data.child('members').child(auth.uid).exists() && newData.child('members').child(auth.uid).exists()))",
        "members": {
          "$uid": {
            ".write": "auth != null && auth.uid === $uid"
          }
        }
      }
    },
    "groupCards": {
      "$gid": {
        ".read": "auth != null && root.child('groups').child($gid).child('members').child(auth.uid).exists()",
        ".write": "auth != null && root.child('groups').child($gid).child('ownerUid').val() === auth.uid",
        "$uid": {
          ".write": "auth != null && auth.uid === $uid && root.child('groups').child($gid).child('members').child(auth.uid).exists()"
        }
      }
    }
  }
}
```

What these enforce:
- A user reads/writes only their own `users/{uid}` node.
- A group is readable only by its members.
- **`groupCards/{gid}/{uid}` is writable only by that same user** who is a member — so a
  friend can see everyone's cards but can **only add/remove their own** (owner-only
  removal). Reads require membership.
- Invite codes are readable by any signed-in user so joining works.

## 3. Put the config into the app
In **Project settings → General → Your apps**, add a **Web app** (or use an existing
one) and copy its config values into
[`lib/services/firebase_config.dart`](../lib/services/firebase_config.dart):

```dart
static const String apiKey = 'AIzaSy...';
static const String projectId = 'your-project-id';
static const String databaseUrl =
    'https://your-project-id-default-rtdb.firebaseio.com';
```

These compile into the app, so the packaged build is self-contained (nothing extra to
ship). Rebuild and the **Sign in** button and **Groups** appear.

The Web API key is **not a secret** — it ships in every Firebase web app, and access is
controlled by the security rules above. For defence in depth, restrict the key in
**Google Cloud Console → APIs & Services → Credentials** to just the *Identity Toolkit
API* and *Firebase Realtime Database*.

## 4. (Optional) Test with the emulator
To try it without touching production, install the Firebase CLI and run
`firebase emulators:start --only auth,database`, then point `databaseUrl` at the emulator
endpoint. Otherwise just create two real accounts to test end-to-end.

## How it's used
- Sign in (top-right) → **Account → Groups…**.
- **Create a group** (get an invite code) or **Join** with a friend's code.
- **Sync my collection to this group** publishes a snapshot of your local cards (with
  their trade tags) under your account. Re-run it whenever your collection changes.
- Everyone in the group sees the pooled binder **live**; each person can remove only
  their own cards.

## Developing / contributing — don't test against the shipped config

**The `firebase_config.dart` that ships in released builds points at the maintainer's
live Firebase project.** The web API key is public by design (see §3), so anyone running
the app authenticates against that same production database. When hacking on the app, do
**not** point your dev builds at it — use your own project or the emulator instead:

- **Your own project:** follow §1–§3 with a Firebase project you own, so your testing is
  fully isolated.
- **Emulator (no cloud at all):** `firebase emulators:start --only auth,database` and
  point `databaseUrl` at the emulator (see §4).

Automated tests are already safe to run and modify freely — `test/cloud_test.dart` uses a
mocked HTTP client and `test/sqlite_backend_test.dart` uses a throwaway local SQLite file,
so **neither touches any real Firebase**. Only *manually running the app* hits whatever
`firebase_config.dart` is set to.

What the rules do and don't protect (so you know what a shared project exposes): the
security rules — not the client code — are the only thing guarding the data, and
modifying the app can't bypass them. But under the rules above, **any signed-in user can
read every invite code, join any group, and read that group's pooled cards** (invite
codes are world-readable to authenticated users). They **cannot** delete or edit groups,
members, or cards they don't own. So treat a shared project as semi-public: card lists and
display names in it are visible to anyone who signs up (emails live in Firebase Auth, not
the database, so those aren't exposed to group members).

## Data model (Realtime Database)

The app writes this tree (see [`lib/services/group_service.dart`](../lib/services/group_service.dart)
and [`lib/models/`](../lib/models)):

```
users/{uid}/groups/{gid}: true          # pointer list — which groups a user is in

invites/{CODE}: { groupId: "{gid}" }     # CODE = 6 chars [A-Z2-9]; maps a code to a group

groups/{gid}: {
  name:       "Kitchen Table",
  ownerUid:   "{uid}",                   # only the owner may delete the group
  inviteCode: "NYV65B",
  createdAt:  "2026-07-18T16:04:10Z",    # ISO-8601 UTC
  members: {
    "{uid}": { displayName: "Alice", role: "owner" }   # role: "owner" | "member"
  }
}

groupCards/{gid}/{uid}/{cardKey}: {      # a member's published cards, keyed by owner uid
  name, setCode, collectorNumber,
  foil: false, quantity: 3,
  imageUrl, priceUsd,                    # nullable
  colors: "WU", colorIdentity: "WUB",    # WUBRG order; "" = colorless
  tags: ["Trade", "Want"],
  updatedAt: "2026-07-19T23:40:55Z"
}
```

- **`cardKey`** is `"{setCode}_{collectorNumber}_{f|n}"` (`f` = foil, `n` = non-foil) with
  RTDB-illegal characters (`. # $ [ ] /`) replaced by `-`, so re-publishing a card updates
  the same node instead of duplicating it.
- Owner attribution for a published card is implied by its path (`groupCards/{gid}/{uid}/…`),
  so the uid isn't repeated inside the value.
- Deleting a group removes `groupCards/{gid}`, `invites/{code}`, and `groups/{gid}`, plus
  the owner's own `users/{uid}/groups/{gid}` pointer; other members' pointers self-heal on
  their next load (their read of the deleted group is denied and the stale pointer is
  pruned).
