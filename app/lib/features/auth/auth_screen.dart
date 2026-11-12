import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/features.dart';

import '../../core/session.dart';
import '../../core/ui.dart';
import 'forgot_password.dart';
import '../../core/i18n.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _signUp = false;
  String _role = 'client';
  bool _busy = false;
  bool _hidePassword = true;

  /// Google sign-in through Supabase Auth. New Google accounts are clients
  /// (dietitians sign up with email so they can upload their credential).
  Future<void> _google() async {
    try {
      await db.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb ? null : 'io.supabase.nouri://login-callback',
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      if (_signUp) {
        final res = await db.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          data: {'role': _role, 'full_name': _name.text.trim()},
        );
        if (res.session == null && mounted) {
          showInfo(context, t('Check your email to confirm your account, then sign in.'));
          setState(() => _signUp = false);
        }
      } else {
        await db.auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t('Nouri'), style: text.displaySmall, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(t('Sign in'))),
                  ButtonSegment(value: true, label: Text(t('Create account'))),
                ],
                selected: {_signUp},
                onSelectionChanged: (s) => setState(() => _signUp = s.first),
              ),
              const SizedBox(height: 16),
              if (_signUp) ...[
                TextField(controller: _name, decoration: InputDecoration(labelText: t('Full name'))),
                const SizedBox(height: 16),
                Text(t('I am a…'), style: text.labelLarge),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'client', icon: Icon(Icons.person_outline), label: Text(t('Client'))),
                    ButtonSegment(value: 'dietitian', icon: Icon(Icons.medical_services_outlined), label: Text(t('Dietitian'))),
                  ],
                  selected: {_role},
                  onSelectionChanged: (s) => setState(() => _role = s.first),
                ),
                if (_role == 'dietitian')
                  Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      t('After signing up you\'ll upload your diploma or certificate. Until it is approved, clients see an "Unverified" badge and you can have up to 3 clients.'),
                    ),
                  ),
              ],
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(labelText: t('Email')),
              ),
              TextField(
                controller: _password,
                obscureText: _hidePassword,
                decoration: InputDecoration(
                  labelText: t('Password'),
                  helperText: _signUp ? t('At least 6 characters') : null,
                  suffixIcon: IconButton(
                    tooltip: _hidePassword ? t('Show password') : t('Hide password'),
                    icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _hidePassword = !_hidePassword),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (!_signUp)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => showForgotPassword(context, initialEmail: _email.text.trim()),
                    child: Text(t('Forgot password?')),
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_signUp ? t('Create account') : t('Sign in')),
              ),
              if (kGoogleSignIn) ...[
                const SizedBox(height: 16),
                Row(children: [
                  const Expanded(child: Divider()),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(t('or'))),
                  const Expanded(child: Divider()),
                ]),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _google,
                  icon: const Text('G', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                  label: Text(t('Continue with Google')),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
