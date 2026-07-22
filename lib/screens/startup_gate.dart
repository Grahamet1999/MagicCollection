import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/collection_store.dart';
import '../services/database_service.dart';
import '../services/db_config.dart';
import '../services/deck_store.dart';
import '../services/firebase_config.dart';
import '../services/group_service.dart';
import 'auth_dialog.dart';
import 'home_page.dart';

/// Gates the app on a successful database connection.
///
/// Instead of crashing at startup when SQL Server is unreachable, this shows a
/// readable error screen with the underlying message and a Retry button, so the
/// user can fix their server/connection and try again without relaunching.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.store,
    required this.deckStore,
    required this.auth,
    required this.groups,
  });

  // The shared services, threaded through to [HomePage] once ready.
  final CollectionStore store;
  final DeckStore deckStore;
  final AuthService auth;
  final GroupService groups;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

/// Connection lifecycle: connecting → ready, or → error (with Retry).
enum _Status { connecting, ready, error }

class _StartupGateState extends State<StartupGate> {
  _Status _status = _Status.connecting;

  /// Underlying error message shown on the error screen.
  String _error = '';

  /// Ensures the one-time launch sign-in prompt only appears once.
  bool _promptedLogin = false;

  /// Offers a one-time sign-in prompt on launch when the cloud is configured but
  /// no session is active. Skippable — the app is fully usable locally.
  Future<void> _promptLogin() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in to shared groups?'),
        content: const Text(
          'Sign in to create or join a group and share your collection with '
          'friends for trading. You can always do this later from the Groups '
          'button in the top bar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (go == true && mounted) showAuthDialog(context, widget.auth);
  }

  @override
  void initState() {
    super.initState();
    _connect();
  }

  /// Initializes the database, loads the stores, and restores any cloud
  /// session. On success moves to [_Status.ready]; on failure captures the
  /// error and moves to [_Status.error] so the user can Retry. Re-run by Retry.
  Future<void> _connect() async {
    setState(() => _status = _Status.connecting);
    try {
      await DatabaseService.instance.init();
      await widget.store.load();
      await widget.deckStore.load();
      // Restore a saved cloud session if the app is configured for Firebase.
      if (FirebaseConfig.isConfigured) {
        await widget.auth.restore();
      }
      if (mounted) setState(() => _status = _Status.ready);
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _Status.error;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case _Status.ready:
        if (FirebaseConfig.isConfigured &&
            !widget.auth.isSignedIn &&
            !_promptedLogin) {
          _promptedLogin = true;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _promptLogin());
        }
        return HomePage(
          store: widget.store,
          deckStore: widget.deckStore,
          auth: widget.auth,
          groups: widget.groups,
        );
      case _Status.connecting:
        return const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Opening your collection…'),
              ],
            ),
          ),
        );
      case _Status.error:
        return _ErrorScreen(message: _error, onRetry: _connect);
    }
  }
}

/// Full-screen connection-failure view: shows the raw error, the configured
/// connection details, a troubleshooting checklist, and a Retry button.
class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.message, required this.onRetry});

  /// The underlying error text (shown verbatim, selectable).
  final String message;

  /// Called when the user taps Retry.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Only Windows desktop ever attempts SQL Server; elsewhere the failure is
    // in the local SQLite file, so the connection checklist doesn't apply.
    final isWindows = Platform.isWindows;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_off, color: scheme.error, size: 32),
                    const SizedBox(width: 12),
                    Text(
                      isWindows
                          ? "Couldn't connect to SQL Server"
                          : "Couldn't open your collection",
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (isWindows) ...[
                  Text(
                    'The app uses ${DbConfig.driver} to reach '
                    '"${DbConfig.server}" (database "${DbConfig.database}", '
                    'Windows authentication).',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                ],
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    message,
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
                if (isWindows) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Things to check:',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text('• The SQL Server service is running.'),
                  const Text(
                    '• The server/instance and driver name in db_config.dart '
                    'match your setup.',
                  ),
                  const Text(
                    '• Your Windows account can connect '
                    '(Windows authentication).',
                  ),
                ],
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
