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

## 3. Create the config file (kept out of git)
In **Project settings → General → Your apps**, add a **Web app** (or use an existing
one) and copy its config values. Then create a **`firebase_config.json`** file with them:

```json
{
  "apiKey": "AIzaSy...",
  "projectId": "your-project-id",
  "databaseUrl": "https://your-project-id-default-rtdb.firebaseio.com"
}
```

This file is **gitignored** so the API key is never committed. Put it in **either**:
- **next to `mtg_collection.exe`** (inside the `MTGApp` folder) — easiest for a packaged
  build and for sharing with friends in the zip; or
- the app-support folder: `%APPDATA%\com.mtgapp\mtg_collection\firebase_config.json`.

The app reads it at launch (checking beside the exe first, then app-support). The Web API
key is **not a secret** — it ships in every Firebase web app and access is controlled by
the rules above — but keeping it in this file avoids committing it to a public repo. The
**Sign in** button and **Groups** appear once the file is present with values.

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
