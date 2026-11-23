import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../state/daily_usage_state.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

class DailyUsagePage extends ConsumerWidget {
  const DailyUsagePage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const DailyUsagePage()),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final tokens = NumberFormat.decimalPattern(locale);
    final date = DateFormat.yMMMd(locale);
    final usage = ref.watch(dailyUsageProvider);
    return AppPage.list(
      title: l10n.tavernUsageStats,
      children: usage.when(
        loading: () => const [Center(child: CircularProgressIndicator())],
        error: (_, _) => [
          ListTile(
            title: Text(l10n.commonFailed),
            trailing: TextButton(
              onPressed: () => ref.invalidate(dailyUsageProvider),
              child: Text(l10n.commonRetry),
            ),
          ),
        ],
        data: (days) => [
          if (days.isEmpty) ListTile(title: Text(l10n.plugViewEmpty)),
          for (final day in days)
            SettingsSection(
              title: date.format(DateTime.parse(day.date)),
              children: [
                _totals(l10n, tokens, l10n.viewChartTotal, day.total),
                _totals(l10n, tokens, l10n.tavernInspectCostPeak, day.peak),
                _totals(l10n, tokens, l10n.tavernInspectCostOffPeak, day.offPeak),
              ],
            ),
        ],
      ),
    );
  }

  static Widget _totals(L10n l10n, NumberFormat tokens, String title, UsageTotals usage) {
    final lines = [
      [
        '${l10n.activityInput} ${tokens.format(usage.input)}',
        '${l10n.activityOutput} ${tokens.format(usage.output)}',
        '${l10n.activityCacheHit} ${tokens.format(usage.cacheRead)}',
      ].join(' · '),
      if (usage.usd case final usd?)
        l10n.activityUsageEstimatedCost('US\$', usd.toStringAsFixed(6)),
      if (usage.unpriced > 0) l10n.tavernSessionUsageUnpriced(usage.unpriced),
    ];
    return ListTile(title: Text(title), subtitle: Text(lines.join('\n')));
  }
}
