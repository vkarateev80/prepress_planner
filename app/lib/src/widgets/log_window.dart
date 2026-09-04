/// Окно «Журнал событий»: лента AppLog с копированием ошибок.
///
/// Открывается из шапки приложения (см. home_shell.dart). Каждая строка —
/// SelectableText внутри SelectionArea, плюс кнопки «Копировать всё»,
/// «Очистить», «Закрыть» — так ошибку можно унести целиком, даже если она
/// длиннее видимой области или экран закрылся.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logs/app_log.dart';

/// Показывает диалог журнала (модально). Несколько раз открывать безопасно:
/// окно переиспользует один и тот же AppLog.
Future<void> showLogWindow(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const LogWindowDialog(),
  );
}

class LogWindowDialog extends StatelessWidget {
  const LogWindowDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long_outlined),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Журнал событий',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  ListenableBuilder(
                    listenable: AppLog.instance,
                    builder: (context, _) => TextButton.icon(
                      onPressed: () => _copyAll(context),
                      icon: const Icon(Icons.copy, size: 18),
                      label: Text('Копировать всё (${AppLog.instance.entries.length})'),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => AppLog.instance.clear(),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('Очистить'),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 8),
            const Expanded(child: _LogList()),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _copyAll(BuildContext context) async {
    final text = AppLog.instance.fullText;
    if (text.isEmpty) {
      _toast(context, 'Журнал пуст.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) _toast(context, 'Скопировано: ${text.length} знаков.');
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }
}

/// Сама лента: свежие записи сверху, строки выделяемые и раскрашенные по
/// уровню. Обновляется по AppLog (ListenableBuilder).
class _LogList extends StatelessWidget {
  const _LogList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: AppLog.instance,
      builder: (context, _) {
        final log = AppLog.instance;
        final all = log.entries;
        if (all.isEmpty) {
          return const Center(
            child: Text('Пока нет записей. Ошибки и этапы работы будут '
                'появляться здесь автоматически.'),
          );
        }
        final newestFirst = all.reversed.toList();
        return SelectionArea(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: newestFirst.length,
            itemBuilder: (context, i) {
              final e = newestFirst[i];
              final color = switch (e.level) {
                LogLevel.error => scheme.error,
                LogLevel.warning => Colors.orange.shade800,
                LogLevel.info => scheme.onSurfaceVariant,
              };
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText.rich(
                  TextSpan(
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        fontFamily: 'monospace',
                        color: scheme.onSurface),
                    children: [
                      TextSpan(
                        text: '${AppLog.stamp(e)} ',
                        style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text:
                            '[${AppLog.levelLetter(e.level)}] [${e.source}] ',
                        style: TextStyle(
                            color: color, fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: e.message,
                        style: TextStyle(color: color),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
