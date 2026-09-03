/// Paywall-экран и статус подписки (заглушка покупки).
library;

import 'package:flutter/material.dart';

import 'entitlement_store.dart';
import 'license_controller.dart';

/// Открывает полноэкранный paywall; покупка идёт через контроллер.
Future<void> openPaywall(
    BuildContext context, LicenseController license) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PaywallScreen(
      timer: license.timer,
      onPurchase: (p) async {
        await license.purchase(p);
        if (context.mounted) Navigator.of(context).pop();
      },
    ),
  ));
}

/// Нижняя шторка «Доступно в Pro» с кнопкой оформления.
Future<void> showProSheet(
  BuildContext context,
  LicenseController license, {
  String? feature,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.workspace_premium,
                    color: Theme.of(sheetContext).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    feature == null ? 'Доступно в Pro' : feature,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Оформите подписку, чтобы открыть эту возможность.'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                openPaywall(context, license);
              },
              child: const Text('Оформить Pro'),
            ),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Позже'),
            ),
          ],
        ),
      ),
    ),
  );
}

class PaywallScreen extends StatelessWidget {
  final TrialTimer timer;
  final ValueChanged<String> onPurchase; // 'month' | 'year'
  const PaywallScreen(
      {super.key, required this.timer, required this.onPurchase});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Препресс-Планер Pro')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.workspace_premium,
                    size: 72, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text(timer.label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 24),
                const Text(
                  'Pro открывает:',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                const Text('• неограниченные проекты\n'
                    '• shape-расход и оптимизация\n'
                    '• ТЭО и сравнение вариантов\n'
                    '• экспорт PDF/XLSX/DXF'),
                const SizedBox(height: 24),
                FilledButton(
                    onPressed: () => onPurchase('month'),
                    child: const Text('Месяц — 990 ₽')),
                const SizedBox(height: 8),
                FilledButton.tonal(
                    onPressed: () => onPurchase('year'),
                    child: const Text('Год — 9 900 ₽ (выгоднее)')),
                const SizedBox(height: 8),
                TextButton(
                    onPressed: () => onPurchase('restore'),
                    child: const Text('Восстановить покупки')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
