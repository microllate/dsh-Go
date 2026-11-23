import 'package:dsh_app/state/daily_usage_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AssistantMessageEvent reply(DateTime time, {String provider = 'deepseek-official'}) =>
    AssistantMessageEvent(
      4,
      time,
      const {},
      turn: 1,
      step: 1,
      message: Message.fromJson({
        'id': 'assistant',
        'role': 'assistant',
        'source': {'kind': 'model', 'provider': provider, 'model': 'deepseek-flash'},
      }),
      usage: const TokenUsage(
        inputTokens: 100,
        outputTokens: 20,
        cacheReadTokens: 200,
        cacheWriteTokens: 10,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('groups by device date, persists cost and deduplicates replays', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(dailyUsageProvider.future);
    final notifier = container.read(dailyUsageProvider.notifier);

    final first = DateTime(2026, 11, 21, 23, 59);
    final second = DateTime(2026, 11, 22);
    final priced = reply(first.toUtc());
    await Future.wait([
      notifier.record('session-a', priced),
      notifier.record('session-a', priced),
      notifier.record('session-b', reply(second.toUtc(), provider: 'custom')),
    ]);

    final reopened = ProviderContainer();
    addTearDown(reopened.dispose);
    await reopened.read(dailyUsageProvider.future);
    await reopened.read(dailyUsageProvider.notifier).record('session-a', priced);
    final days = await reopened.read(dailyUsageProvider.future);
    expect(days.map((day) => day.date), ['2026-11-22', '2026-11-21']);
    expect(days.first.total.input, 310);
    expect(days.first.total.unpriced, 1);
    expect(days.first.total.cny, isNull);
    expect(days.last.total.input, 310);
    expect(days.last.total.output, 20);
    expect(days.last.total.cacheRead, 200);
    expect(days.last.total.cny, closeTo(0.000194, 1e-10));
  });

  test('splits persisted replies at weekday peak boundaries', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(dailyUsageProvider.future);
    final notifier = container.read(dailyUsageProvider.notifier);
    for (final time in [
      DateTime.utc(2026, 11, 23, 0, 59),
      DateTime.utc(2026, 11, 23, 1),
      DateTime.utc(2026, 11, 23, 3, 59),
      DateTime.utc(2026, 11, 23, 4),
      DateTime.utc(2026, 11, 23, 6),
      DateTime.utc(2026, 11, 23, 10),
    ]) {
      await notifier.record('session-a', reply(time));
    }
    final days = await container.read(dailyUsageProvider.future);
    final peak = days.fold(const UsageTotals(), (sum, day) => sum + day.peak);
    final offPeak = days.fold(const UsageTotals(), (sum, day) => sum + day.offPeak);
    expect(peak.input, 3 * 310);
    expect(offPeak.input, peak.input);
    expect(peak.output, 3 * 20);
    expect(offPeak.cacheRead, 3 * 200);
    expect(peak.cost!.hit, closeTo(3 * 0.000008, 1e-10));
    expect(peak.cost!.miss, closeTo(3 * 0.000220, 1e-10));
    expect(peak.cost!.out, closeTo(3 * 0.000160, 1e-10));
    expect(peak.cny, closeTo(3 * 0.000388, 1e-10));
    expect(offPeak.cny, closeTo(3 * 0.000194, 1e-10));
  });
}
