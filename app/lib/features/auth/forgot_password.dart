import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import '../../core/i18n.dart';

/// Two steps: email -> 6-digit code + new password.
///
/// Uses a code rather than a link so it works the same on phones and the web
/// without deep-link setup. In production the Supabase "Reset password" email
/// template must include {{ .Token }}.
Future<void> showForgotPassword(BuildContext context, {String initialEmail = ''}) =>
    showDialog<void>(context: context, builder: (_) => _ForgotPasswordDialog(initialEmail: initialEmail));

class _ForgotPasswordDialog extends StatefulWidget {
  const _ForgotPasswordDialog({required this.initialEmail});
  final String initialEmail;

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = t('Enter the email you signed up with.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await db.auth.resetPasswordForEmail(email);
      // Release focus before the email field is swapped out for the code
      // fields; removing a focused field trips an error in Flutter web.
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted) setState(() => _codeSent = true);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    final code = _code.text.trim();
    final password = _password.text;
    // Validate before using the code: verifying it signs the user in.
    final problem = code.length != 6
        ? t('Enter the 6-digit code from the email.')
        : password.length < 6
            ? t('The new password must be at least 6 characters.')
            : password != _confirm.text
                ? t('The passwords don\'t match.')
                : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await db.auth.verifyOTP(email: _email.text.trim(), token: code, type: OtpType.recovery);
      await db.auth.updateUser(UserAttributes(password: password));
      // Signing in may already have moved the app to the home screen and
      // removed this dialog; only close it if it is still there.
      if (mounted) navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(t('Password changed. You are now signed in.'))));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_codeSent ? t('Enter the code') : t('Reset your password')),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!_codeSent) ...[
            Text(t('Enter your account email. We\'ll send you a 6-digit code to set a new password.')),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: t('Email')),
              onSubmitted: (_) => _sendCode(),
            ),
          ] else ...[
            Text(t('If an account exists for {0}, a code is on its way. Check your inbox (and spam folder).', [_email.text.trim()])),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 22, letterSpacing: 6),
              decoration: InputDecoration(labelText: t('6-digit code'), counterText: ''),
            ),
            TextField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: t('New password'),
                helperText: t('At least 6 characters'),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            TextField(
              controller: _confirm,
              obscureText: _obscure,
              decoration: InputDecoration(labelText: t('Repeat new password')),
              onSubmitted: (_) => _reset(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: _busy ? null : _sendCode, child: Text(t('Send a new code'))),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
        FilledButton(
          onPressed: _busy ? null : (_codeSent ? _reset : _sendCode),
          child: Text(_codeSent ? t('Set new password') : t('Send code')),
        ),
      ],
    );
  }
}
