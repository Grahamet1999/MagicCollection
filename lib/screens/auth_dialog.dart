import 'package:flutter/material.dart';

import '../services/auth_service.dart';

/// Shows the sign-in / create-account dialog for the cloud group feature.
Future<void> showAuthDialog(BuildContext context, AuthService auth) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AuthDialog(auth: auth),
  );
}

/// The stateful body of the auth dialog; toggles between sign-in and sign-up.
class _AuthDialog extends StatefulWidget {
  const _AuthDialog({required this.auth});
  final AuthService auth;

  @override
  State<_AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<_AuthDialog> {
  /// False = sign in, true = create account (shows the display-name field).
  bool _signUp = false;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  /// True while a request is in flight; disables the submit button.
  bool _busy = false;

  /// Last error message to display, or null.
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Runs sign-in or sign-up depending on [_signUp], closing the dialog on
  /// success or showing the error inline on failure. For sign-up, an empty
  /// display name falls back to the email address.
  Future<void> _submit() async {
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signUp) {
        await widget.auth.signUp(
          _email.text.trim(),
          _password.text,
          _name.text.trim().isEmpty ? _email.text.trim() : _name.text.trim(),
        );
      } else {
        await widget.auth.signIn(_email.text.trim(), _password.text);
      }
      navigator.pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_signUp ? 'Create account' : 'Sign in'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_signUp)
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
              ),
            ),
          if (_signUp) const SizedBox(height: 8),
          TextField(
            controller: _email,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _password,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            onSubmitted: (_) => _busy ? null : _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                _signUp = !_signUp;
                _error = null;
              }),
              child: Text(_signUp
                  ? 'Have an account? Sign in'
                  : 'New here? Create an account'),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_signUp ? 'Create account' : 'Sign in'),
        ),
      ],
    );
  }
}
