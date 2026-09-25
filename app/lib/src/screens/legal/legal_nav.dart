/// Вспомогательный виджет для навигации по юридическим разделам.
library;

import 'package:flutter/material.dart';

/// Боковая панель с навигацией по разделам юридической информации.
class LegalNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSectionSelected;

  const LegalNav({
    super.key,
    required this.selectedIndex,
    required this.onSectionSelected,
  });

  static const _sections = [
    ('Реквизиты', Icons.account_balance_wallet_outlined),
    ('Политика конфиденциальности', Icons.privacy_tip_outlined),
    ('Пользовательское соглашение', Icons.description_outlined),
    ('Защита персональных данных', Icons.shield_outlined),
    ('Лицензионное соглашение', Icons.verified_user_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: _sections.asMap().entries.map((entry) {
        final index = entry.key;
        final (title, icon) = entry.value;
        final isSelected = index == selectedIndex;
        return ListTile(
          selected: isSelected,
          selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
          leading: Icon(
            icon,
            size: 20,
            color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
          ),
          title: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected ? colorScheme.primary : colorScheme.onSurface,
            ),
          ),
          onTap: () => onSectionSelected(index),
        );
      }).toList(),
    );
  }
}
