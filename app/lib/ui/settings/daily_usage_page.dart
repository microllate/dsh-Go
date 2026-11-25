import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshHttpException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/daily_usage_state.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

class DailyUsagePage extends ConsumerStatefulWidget {
  const DailyUsagePage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const DailyUsagePage()));

  @override
  ConsumerState<DailyUsagePage> createState() => _DailyUsagePageState();
}

class _DailyUsagePageState extends ConsumerState<DailyUsagePage> {
  bool _syncing = false;
  String? _syncError;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    String? failure;
    try {
      await ref.read(dailyUsageProvider.notifier).syncEngine();
    } on Object catch (error) {
      failure = switch (error) {
        DshHttpException(:final statusCode) => 'HTTP $statusCode',
        _ => error.runtimeType.toString(),
      };
      debugPrint('Daily usage sync failed: $failure');
    }
    if (mounted) {
      setState(() {
        _syncing = false;
        _syncError = failure;
      });
    }
  }

  Future<void> _deleteDay(String day, String label) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.settingsDailyUsageDelete),
        content: Text(l10n.settingsDailyUsageDeleteDetail(label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.commonDelete)),
        ],
      ),
    );
    if (confirmed == true && mounted) await ref.read(dailyUsageProvider.notifier).deleteDay(day);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeConnectionProvider, (previous, next) {
      if (next.value?.isLocal == true && !identical(previous?.value, next.value)) {
        unawaited(_refresh());
      }
    });
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
              onPressed: _syncing ? null : () => unawaited(_refresh()),
              child: Text(l10n.commonRetry),
            ),
          ),
        ],
        data: (days) => [
          if (_syncError case final error?)
            ListTile(
              title: Text(l10n.settingsDailyUsageSyncFailed),
              subtitle: Text(error),
              trailing: TextButton(
                onPressed: _syncing ? null : () => unawaited(_refresh()),
                child: Text(l10n.commonRetry),
              ),
            ),
          if (days.isEmpty) ListTile(title: Text(l10n.plugViewEmpty)),
          for (final day in days)
            SettingsSection(
              title: date.format(DateTime.parse(day.date)),
              children: [
                _totals(l10n, tokens, l10n.viewChartTotal, day.total),
                _totals(l10n, tokens, l10n.tavernInspectCostPeak, day.peak),
                _totals(l10n, tokens, l10n.tavernInspectCostOffPeak, day.offPeak),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(l10n.settingsDailyUsageDelete),
                  onTap: () => unawaited(_deleteDay(day.date, date.format(DateTime.parse(day.date)))),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static Widget _totals(L10n l10n, NumberFormat tokens, String title, UsageTotals usage) {
    String amount(double cny) => l10n.activityUsageEstimatedCost('¥', cny.toStringAsFixed(2));
    String line(String label, int count, double? cny) =>
        [label.trim(), tokens.format(count), if (cny != null) amount(cny)].join(' · ');
    final lines = [
      line(l10n.activityStepCacheHit, usage.cacheRead, usage.cost?.hit),
      line(l10n.activityStepCacheMiss, usage.input - usage.cacheRead, usage.cost?.miss),
      line(l10n.activityOutput, usage.output, usage.cost?.out),
      if (usage.cny case final cny?) '${l10n.viewChartTotal} ${amount(cny)}',
      if (usage.unpriced > 0) l10n.tavernSessionUsageUnpriced(usage.unpriced),
    ];
    return ListTile(title: Text(title), subtitle: Text(lines.join('\n')));
  }
}
