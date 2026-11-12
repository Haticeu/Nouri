import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../widgets/common.dart';
import 'client_messages_tab.dart';
import 'my_dietitian_screen.dart';
import 'progress_screen.dart';
import 'today_screen.dart';
import '../../core/i18n.dart';

class ClientShell extends StatefulWidget {
  const ClientShell({super.key, required this.session});
  final AppSession session;

  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell> {
  int _tab = 0;
  static const _messagesTab = 3;
  static final _titles = [t('Today'), t('Progress'), t('My Dietitian'), t('Messages')];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Today shows its own greeting header instead of a bar title.
        title: _tab == 0 ? null : Text(_titles[_tab]),
        actions: [const NotificationsButton(), AccountMenu(session: widget.session)],
      ),
      body: IndexedStack(index: _tab, children: [
        const TodayScreen(),
        const ProgressScreen(),
        const MyDietitianScreen(),
        // Built only while open: an open chat marks messages as read.
        if (_tab == _messagesTab) const ClientMessagesTab() else const SizedBox.shrink(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.restaurant_outlined), label: t('Today')),
          NavigationDestination(icon: const Icon(Icons.show_chart), label: t('Progress')),
          NavigationDestination(icon: const Icon(Icons.support_agent_outlined), label: t('My Dietitian')),
          NavigationDestination(
            icon: ClientUnreadIcon(selected: _tab == _messagesTab),
            label: t('Messages'),
          ),
        ],
      ),
    );
  }
}
