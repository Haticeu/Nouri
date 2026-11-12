import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/session.dart';
import 'core/i18n.dart';

// Pass credentials at build time:
//   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
// SUPABASE_KEY is the project's publishable key (the legacy anon key also works).
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseKey = String.fromEnvironment('SUPABASE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initI18n(); // device language (Turkish or English), before any text or date is built
  if (_supabaseUrl.isEmpty || _supabaseKey.isEmpty) {
    runApp(const _MissingConfigApp());
    return;
  }
  await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseKey);
  final session = AppSession();
  await session.load();
  runApp(NouriApp(session: session));
}

class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              t('Supabase is not configured.\n\nRun with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
