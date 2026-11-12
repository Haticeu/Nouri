import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../widgets/common.dart';
import 'broadcasts_screen.dart';
import 'clients_overview_screen.dart';
import 'foods_screen.dart';
import 'messages_screen.dart';
import 'profile_screen.dart';
import 'templates_screen.dart';
import '../../core/i18n.dart';

/// Dietitian workspace. Side rail on desktop/web, bottom bar on phones.
class DietitianShell extends StatefulWidget {
  const DietitianShell({super.key, required this.session});
  final AppSession session;

  @override
  State<DietitianShell> createState() => _DietitianShellState();
}

class _DietitianShellState extends State<DietitianShell> {
  int _tab = 0;

  static const _messagesTab = 1;
  static const _workspaceTab = 5;
  static final _dests = [
    (Icons.people_outline, Icons.people, t('Clients')),
    (Icons.chat_outlined, Icons.chat, t('Messages')),
    (Icons.campaign_outlined, Icons.campaign, t('Tips & updates')),
    (Icons.restaurant_menu_outlined, Icons.restaurant_menu, t('Plan templates')),
    (Icons.menu_book_outlined, Icons.menu_book, t('Foods')),
    (Icons.badge_outlined, Icons.badge, t('Workspace')),
  ];

  /// Messages gets a live unread badge; the rest are plain icons.
  Widget _icon(int i, {required bool selected}) => i == _messagesTab
      ? UnreadMessagesIcon(selected: selected)
      : Icon(selected ? _dests[i].$2 : _dests[i].$1);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final body = IndexedStack(index: _tab, children: [
      ClientsOverviewScreen(onOpenProfile: () => setState(() => _tab = _workspaceTab)),
      const MessagesScreen(),
      const BroadcastsScreen(),
      const TemplatesScreen(),
      FoodsScreen(session: widget.session),
      const DietitianProfileScreen(),
    ]);
    return Scaffold(
      appBar: AppBar(
        title: Text(_dests[_tab].$3),
        actions: [const NotificationsButton(), AccountMenu(session: widget.session)],
      ),
      body: wide
          ? Row(children: [
              NavigationRail(
                selectedIndex: _tab,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: [
                  for (var i = 0; i < _dests.length; i++)
                    NavigationRailDestination(
                      icon: _icon(i, selected: false),
                      selectedIcon: _icon(i, selected: true),
                      label: Text(_dests[i].$3),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ])
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (var i = 0; i < _dests.length; i++)
                  NavigationDestination(
                    icon: _icon(i, selected: false),
                    selectedIcon: _icon(i, selected: true),
                    label: _dests[i].$3,
                  ),
              ],
            ),
    );
  }
}
