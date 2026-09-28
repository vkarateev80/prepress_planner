/// Экран «Юридическая информация»: реквизиты, политики, соглашения.
library;

import 'package:flutter/material.dart';

/// Секции юридической информации.
class LegalScreen extends StatefulWidget {
  const LegalScreen({super.key});

  @override
  State<LegalScreen> createState() => _LegalScreenState();
}

class _LegalScreenState extends State<LegalScreen> {
  int _selectedIndex = 0;

  static const _sections = [
    ('Реквизиты', Icons.account_balance_wallet_outlined),
    ('Политика конфиденциальности', Icons.privacy_tip_outlined),
    ('Пользовательское соглашение', Icons.description_outlined),
    ('Защита персональных данных', Icons.shield_outlined),
    ('Лицензионное соглашение', Icons.verified_user_outlined),
  ];

  // Юридические тексты — вынесены в константы, чтобы
  // не было проблем с парсингом многострочных строк.
  static const _requisitesTitle = 'Юридические реквизиты';
  static const _requisitesSubtitle =
      'Сведения для заключения договора и оплаты услуг.';

  static const _requisitesOrg = 'ИП Каратеева И. О.';
  static const _requisitesInn = '332905240930';
  static const _requisitesOgrn = '326330000052193'; // ОГРНИП
  static const _requisitesPhone = '+7 993 600-19-80';
  static const _requisitesEmail = 'info@prepressplan.ru';
  static const _requisitesSite = 'prepressplan.ru';

  static const _privacyTitle = 'Политика конфиденциальности';
  static const _privacySubtitle =
      'Политика обработки персональных данных в сервисе «Препресс-Планер».';

  static const _privacySections = [
    '1. Общие положения',
    '2. Какие персональные данные мы собираем',
    '3. Цели обработки персональных данных',
    '4. Законные основания обработки',
    '5. Передача третьим лицам',
    '6. Хранение и защита',
    '7. Права субъекта данных',
    '8. Срок хранения',
    '9. Обновление политики',
    '10. Контакты',
  ];

  static const _privacyTexts = [
    'Настоящая политика конфиденциальности действует в отношении всех '
        'персональных данных, которые могут быть получены сервисом '
        '«Препресс-Планер» при регистрации, использовании сервиса или '
        'оплате услуг.',
    'Фамилия, имя, отчество\nЭлектронная почта\nТелефон (при необходимости)\n'
        'IP-адрес и данные об устройстве (для анализа и поддержки)\n'
        'Платежные данные (через сторонние платёжные системы)',
    'Идентификация пользователя и предоставление доступа к сервису\n'
        'Выполнение договорных обязательств\nОказание технической поддержки\n'
        'Направление технической и рекламной информации (с согласия)\n'
        'Статистическая обработка (анонимная)',
    'Согласие пользователя (ст. 6 ч. 1 п. 1 152-ФЗ)\n'
        'Необходимость для исполнения договора (ст. 6 ч. 1 п. 2 152-ФЗ)\n'
        'Обработка данных подразделениями, предусмотренными законодательством',
    'Персональные данные не передаются третьим лицам, за исключением:\n'
        'ЮKassa (платёжный процессор) — для обработки платежей\n'
        'Авторизованные лица (по запросу правоохранительных органов)',
    'Данные хранятся на защищённых серверах с ограниченным доступом. Мы '
        'принимаем меры по защите информации от несанкционированного доступа, '
        'изменения, раскрытия или уничтожения.',
    'Пользователь вправе:\nЗапросить информацию о наличии и содержании '
        'своих данных\nТребовать исправления или удаления данных\nОтозвать '
        'согласие на обработку\nПодать жалобу в надзорный орган (Роскомнадзор)',
    'Персональные данные хранятся в течение необходимого срока для '
        'осуществления целей обработки, не более 75 лет, если иное не '
        'предусмотрено законодательством или договором.',
    'Настоящая политика может быть изменена. Актуальная редакция всегда '
        'доступна на данном объекте сайта.',
    'По вопросам обработки персональных данных:\nEmail: mail@prepressplan.ru\n'
        'Телефон: +7 993 600-19-80',
  ];

  static const _termsTitle = 'Пользовательское соглашение';
  static const _termsSubtitle = 'Условия использования сервиса «Препресс-Планер».';

  static const _termsSections = [
    '1. Общие условия',
    '2. Определения',
    '3. Права и обязанности Пользователя',
    '4. Права и обязанности Сервиса',
    '5. Лицензия',
    '6. Гарантии',
    '7. Ограничение ответственности',
    '8. Прекращение использования',
    '9. Разрешение споров',
  ];

  static const _termsTexts = [
    'Настоящее соглашение регулирует отношения между сервисом '
        '«Препресс-Планер» и пользователем. Использование сервиса означает '
        'согласие пользователя с данными условиями.',
    'Сервис — программное обеспечение «Препресс-Планер» и соответствующие '
        'услуги.\nПользователь — лицо, использующее сервис на законных '
        'основаниях.\nПодписка — облада права доступа к сервису на определённый '
        'срок.',
    'Пользователь обязуется:\nИспользовать сервис в законных целях\nНе '
        'нарушать права других пользователей\nНе пытаться обойти защиту '
        'сервиса\nОплачивать подписку в установленный срок\nВыполнять '
        'требования техподдержки',
    'Сервис обязуется:\nОбеспечивать доступ к сервису в установленное время\n'
        'Обеспечивать сохранность данных пользователя\nОказывать техническую '
        'поддержку\nНе использовать данные пользователя в коммерческих целях',
    'Пользователь получает право на использование сервиса на условиях '
        'лицензии, определяемой тарифом. Безвозмездная лицензия не предоставляет '
        'прав на 재판매 или модификацию.',
    'Сервис гарантирует отсутствие вирусов и вредоносного кода. Сервис не '
        'гарантирует безошибочную работу и не несёт ответственности за развитие '
        'событий, не связанных с использованием сервиса.',
    'Сервис не несёт ответственности за любые прямые или косвенные убытки, '
        'возникшие вследствие использования сервиса или невозможности его '
        'использования, включая убытки данных.',
    'Сервис вправе прекратить использование сервиса в случае:\nНарушения '
        'настоящего соглашения\nНевнесения оплаты в установленный срок\nОстаться '
        'лицом, не достигшим возраста 18 лет, без согласия родителей',
    'Все споры решаются путём переговоров. В случае невозможности '
        'договориться, спор передаётся в Арбитражный суд Москвы.',
  ];

  static const _dataProtectionTitle = 'Защита персональных данных';
  static const _dataProtectionSubtitle =
      'Сведения об обработке персональных данных в соответствии с 152-ФЗ.';

  static const _dataProtectionInfo =
      'Мы собираем и используем персональные данные строго в соответствии с '
          'Федеральным законом № 152-ФЗ «О персональных данных».';

  static const _dataProtectionSections = [
    'Наименование оператора',
    'Цели обработки',
    'Категории персональных данных',
    'Срок хранения',
    'Права субъекта',
    'Контакты для запросов',
  ];

  static const _dataProtectionTexts = [
    'ИП Каратеева И. О.\nИНН: 332905240930\nОГРНИП: 326330000052193',
    'Идентификация личности\nПредоставление доступа к сервису\nОплата услуг '
        'и выставление счетов\nСтатистический анализ',
    'Фамилия, имя, отчество\nEmail\nКонтактный телефон\nIP-адрес и данные об '
        'устройстве\nПлатежные данные (опосредованно)',
    'Данные хранятся в течение использования сервиса. После закрытия '
        'аккаунта данные удаляются в течение 30 дней.',
    'Пользователь вправе:\nПолучить информацию о своих данных\nИсправить '
        'неточные данные\nЗапросить удаление данных\nОтозвать согласие',
    'Email: dpo@prepressplan.ru\nТелефон: +7 993 600-19-80',
  ];

  static const _licenseTitle = 'Лицензионное соглашение';
  static const _licenseSubtitle =
      'Условия использования платёжной системы ЮKassa и лицензирование.';

  static const _licenseSections = [
    '1. Общие положения',
    '2. Платёжная система',
    '3. Стоимость услуг',
    '4. Триал',
    '5. Лицензия',
    '6. Возврат',
    '7. Изменение условий',
    '8. Контакты',
  ];

  static const _licenseTexts = [
    'Настоящее соглашение регулирует использование сервиса «Препресс-Планер» '
        'и интеграции с платёжной системой ЮKassa.',
    'Для оплаты услуг используется платёжная система ЮKassa (Яндекс). При '
        'оплате пользователь перенаправляется на сайт ЮKassa, где происходит '
        'авторизация и выполнение платежа.',
    'Pro на месяц: 5000 руб.\nPro на год: 50000 руб.\nFree: бесплатно '
        '(ограниченный функционал)',
    'При первом использовании предоставляется триал на 15 дней. После '
        'окончания триал автоматически переводится в Free тариф.',
    'Пользователь получает право на использование сервиса в соответствии с '
        'тарифом. При оплате предоставляется лицензия на использование '
        'программного обеспечения.',
    'Возврат средств возможен в счёт будущих платежей или прямым возвратом '
        'через платёжную систему (согласно правилам ЮKassa).',
    'Сервис оставляет за собой право изменять условия настоящего соглашения. '
        'Об изменениях пользователь уведомляется заранее.',
    'По вопросам лицензирования:\nEmail: support@prepressplan.ru\nТелефон: '
        '+7 993 600-19-80',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Юридическая информация'),
      ),
      body: Row(
        children: [
          // Боковое меню
          Container(
            width: 260,
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            // Material между ColoredBox(ListTile-контейнером) и ListTile —
            // без него срабатывает assert фреймворка (ink/выделение
            // рисуются на ближайшем Material и прячутся под ColoredBox).
            child: Material(
              color: Colors.transparent,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: _sections.map((section) {
                  final index = _sections.indexOf(section);
                  final isSelected = index == _selectedIndex;
                  return ListTile(
                    selected: isSelected,
                    selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
                    leading: Icon(
                      section.$2,
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      section.$1,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => setState(() => _selectedIndex = index),
                  );
                }).toList(),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          // Контент
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: _buildContent(context, _selectedIndex),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, int index) {
    switch (index) {
      case 0:
        return _buildRequisites(context);
      case 1:
        return _buildPrivacyPolicy(context);
      case 2:
        return _buildTermsOfService(context);
      case 3:
        return _buildDataProtection(context);
      case 4:
        return _buildLicenseAgreement(context);
      default:
        return const SizedBox();
    }
  }

  Widget _buildRequisites(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _requisitesTitle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _requisitesSubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow(context, 'Организация', _requisitesOrg),
                const Divider(height: 1),
                _buildInfoRow(context, 'ИНН', _requisitesInn),
                const Divider(height: 1),
                _buildInfoRow(context, 'ОГРНИП', _requisitesOgrn),
                const Divider(height: 1),
                _buildInfoRow(context, 'Телефон', _requisitesPhone),
                const Divider(height: 1),
                _buildInfoRow(context, 'Email', _requisitesEmail),
                const Divider(height: 1),
                _buildInfoRow(context, 'Сайт', _requisitesSite),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Оплата',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Подписка Pro оплачивается банковской картой онлайн через '
                  'платёжную систему ЮKassa в разделе аккаунта. Электронный '
                  'чек приходит на email после подтверждения платежа. '
                  'Порядок оплаты и получения — на странице тарифов '
                  'prepressplan.ru/legal/pricing.html.',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildPrivacyPolicy(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _privacyTitle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _privacySubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        ...List.generate(_privacySections.length, (i) {
          return _buildSection(
            context,
            _privacySections[i],
            _privacyTexts[i],
          );
        }),
      ],
    );
  }

  Widget _buildTermsOfService(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _termsTitle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _termsSubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        ...List.generate(_termsSections.length, (i) {
          return _buildSection(
            context,
            _termsSections[i],
            _termsTexts[i],
          );
        }),
      ],
    );
  }

  Widget _buildDataProtection(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _dataProtectionTitle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _dataProtectionSubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Card(
          color: colorScheme.primaryContainer.withValues(alpha: 0.2),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 20, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Учёт персональных данных',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _dataProtectionInfo,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ...List.generate(_dataProtectionSections.length, (i) {
          return _buildSection(
            context,
            _dataProtectionSections[i],
            _dataProtectionTexts[i],
          );
        }),
      ],
    );
  }

  Widget _buildLicenseAgreement(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _licenseTitle,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _licenseSubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        ...List.generate(_licenseSections.length, (i) {
          return _buildSection(
            context,
            _licenseSections[i],
            _licenseTexts[i],
          );
        }),
      ],
    );
  }

  Widget _buildSection(BuildContext context, String title, String content) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          content,
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
