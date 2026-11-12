import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'core/session.dart';
import 'core/theme.dart';
import 'features/admin/admin_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/chat/chat_screen.dart';
import 'features/client/client_shell.dart';
import 'features/client/find_dietitian_screen.dart';
import 'features/client/join_screen.dart';
import 'features/dietitian/client_detail_screen.dart';
import 'features/dietitian/dietitian_shell.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/profile/profile_screen.dart';
import 'core/i18n.dart';

class NouriApp extends StatefulWidget {
  const NouriApp({super.key, required this.session});
  final AppSession session;

  @override
  State<NouriApp> createState() => _NouriAppState();
}

class _NouriAppState extends State<NouriApp> {
  late final GoRouter _router = GoRouter(
    refreshListenable: widget.session,
    initialLocation: '/',
    redirect: (context, state) {
      final s = widget.session;
      if (s.loading) return null;
      final loc = state.matchedLocation;
      if (!s.signedIn) return loc == '/auth' ? null : '/auth';
      final home = s.role == UserRole.dietitian ? '/d' : '/c';
      // New clients answer a few questions first.
      if (s.needsOnboarding) return loc == '/welcome' ? null : '/welcome';
      if (loc == '/welcome') return home;
      if (loc == '/auth' || loc == '/') return home;
      // Keep each role inside its own area.
      if (s.role == UserRole.dietitian && (loc.startsWith('/c') || loc == '/join' || loc.startsWith('/dietitians'))) return home;
      // The dietitian area is /d and /d/...; /dietitians is the client's directory.
      if (s.role == UserRole.client && (loc == '/d' || loc.startsWith('/d/'))) return home;
      if (loc == '/admin' && !s.isAdmin) return home;
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Center(child: CircularProgressIndicator()))),
      GoRoute(path: '/auth', builder: (_, _) => const AuthScreen()),
      GoRoute(path: '/c', builder: (_, _) => ClientShell(session: widget.session)),
      GoRoute(path: '/join', builder: (_, _) => const JoinScreen()),
      GoRoute(path: '/dietitians', builder: (_, _) => const FindDietitianScreen()),
      GoRoute(
        path: '/dietitians/:id',
        builder: (_, state) => DietitianDetailScreen(dietitianId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/welcome', builder: (_, _) => OnboardingScreen(session: widget.session)),
      GoRoute(path: '/d', builder: (_, _) => DietitianShell(session: widget.session)),
      GoRoute(
        path: '/d/client/:id',
        builder: (_, state) => ClientDetailScreen(clientId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chat/:dietitianId/:clientId',
        builder: (_, state) => ChatScreen(
          dietitianId: state.pathParameters['dietitianId']!,
          clientId: state.pathParameters['clientId']!,
        ),
      ),
      GoRoute(path: '/notifications', builder: (_, _) => const NotificationsScreen()),
      GoRoute(path: '/admin', builder: (_, _) => const AdminScreen()),
      GoRoute(path: '/profile', builder: (_, _) => ProfileScreen(session: widget.session)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: t('Nouri'),
      debugShowCheckedModeBanner: false,
      // Follows the device's light/dark setting (ThemeMode.system), no in-app toggle.
      theme: nouriTheme(Brightness.light),
      darkTheme: nouriTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      // Same language as the device (see initI18n); Material widgets such as
      // date pickers follow it too.
      locale: Locale(appLang),
      supportedLocales: supportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: _router,
    );
  }
}
