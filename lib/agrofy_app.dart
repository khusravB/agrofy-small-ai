
import 'package:material_ui/material_ui.dart';

import 'app_events.dart';
import 'screens/home_screen.dart';
import 'screens/fields_screen.dart';
import 'screens/map_screen.dart';
import 'screens/ai_screen.dart';
import 'screens/knowledge_screen.dart';

class AgrofyApp extends StatelessWidget {
  const AgrofyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AGROFY',
      home: MainNavigation(),
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    requestedTab.addListener(_openRequestedTab);
  }

  @override
  void dispose() {
    requestedTab.removeListener(_openRequestedTab);
    super.dispose();
  }

  void _openRequestedTab() {
    final index = requestedTab.value;
    if (index == null || !mounted) {
      return;
    }

    setState(() => _selectedIndex = index);
    requestedTab.value = null;
    notifyDataChanged();
  }

  static const List<Widget> _screens = [
    HomeScreen(),
    FieldsScreen(),
    MapScreen(),
    AIScreen(),
    KnowledgeScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
          // Вкладки перечитывают участки: данные могли измениться
          // на другой вкладке.
          notifyDataChanged();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Поля',
          ),
          NavigationDestination(
            icon: Icon(Icons.public_outlined),
            selectedIcon: Icon(Icons.public),
            label: 'Карта',
          ),
          NavigationDestination(
            icon: Icon(Icons.smart_toy_outlined),
            selectedIcon: Icon(Icons.smart_toy),
            label: 'AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: 'Знания',
          ),
        ],
      ),
    );
  }
}
