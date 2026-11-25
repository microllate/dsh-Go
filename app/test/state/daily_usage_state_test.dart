import 'package:dsh_app/state/daily_usage_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_tavern/dsh_tavern.dart' show TavernUsage;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AssistantMessageEvent reply(DateTime time, {String provider = 'deepseek-official'}) => AssistantMessageEvent(
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
  usage: const TokenUsage(inputTokens: 100, outputTokens: 20, cacheReadTokens: 200, cacheWriteTokens: 10),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deletes one day and ignores replayed records from before deletion', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(dailyUsageProvider.future);
    final notifier = container.read(dailyUsageProvider.notifier);
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 12);
    final other = DateTime(now.year, now.month, now.day - 2, 12);
    String day(DateTime time) => time.toIso8601String().split('T').first;
    await notifier.record('yesterday', reply(yesterday));
    await notifier.record('other', reply(other));
    await notifier.deleteDay(day(yesterday));
    await notifier.record('yesterday', reply(yesterday));
    final days = await container.read(dailyUsageProvider.future);
    expect(days.map((day) => day.date), [day(other)]);
  });

  test('keeps old device dates and deduplicates historical estimates', () async {
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
    expect(days.first.legacy.input, 310);
    expect(days.first.legacy.unpriced, 1);
    expect(days.first.legacy.cny, isNull);
    expect(days.last.legacy.input, 310);
    expect(days.last.legacy.output, 20);
    expect(days.last.legacy.cacheRead, 200);
    expect(days.last.legacy.cny, closeTo(0.000194, 1e-10));
    expect(days.every((day) => day.total.isEmpty), isTrue);
  });

  test('splits settled requests at weekday peak boundaries', () async {
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
      await notifier.recordTavern(
        Uri.parse('https://api.deepseek.com/beta/chat/completions'),
        const TavernUsage(promptTokens: 310, cacheHitTokens: 200, completionTokens: 20, model: 'deepseek-flash'),
        time,
      );
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

  test('keeps historical estimates apart and prices only official endpoints', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(dailyUsageProvider.future);
    final notifier = container.read(dailyUsageProvider.notifier);
    final at = DateTime.utc(2026, 11, 23, 2);
    const usage = TavernUsage(promptTokens: 100, cacheHitTokens: 80, completionTokens: 9, model: 'deepseek-flash');
    await notifier.record('session-a', reply(at));
    await notifier.recordTavern(Uri.parse('https://api.deepseek.com/beta/chat/completions'), usage, at);
    await notifier.recordTavern(Uri.parse('https://relay.example.test/v1/chat/completions'), usage, at);

    final days = await container.read(dailyUsageProvider.future);
    final total = days.single.peak;
    expect(days.single.legacy.input, 310);
    expect(total.input, 200);
    expect(total.cacheRead, 160);
    expect(total.output, 18);
    expect(total.unpriced, 1);
    expect(total.cost!.hit, closeTo(0.0000032, 1e-10));
    expect(total.cost!.miss, closeTo(0.000040, 1e-10));
    expect(total.cost!.out, closeTo(0.000072, 1e-10));
  });
}
