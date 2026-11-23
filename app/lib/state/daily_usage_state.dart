import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tavern/tavern_session_usage.dart';

final dailyUsageProvider = AsyncNotifierProvider<DailyUsageController, List<DailyUsage>>(
  DailyUsageController.new,
);

class DailyUsage {
  const DailyUsage(this.date, this.peak, this.offPeak);

  final String date;
  final UsageTotals peak;
  final UsageTotals offPeak;

  UsageTotals get total => peak + offPeak;
}

typedef UsagePrice = ({double hit, double miss, double out});

class UsageTotals {
  const UsageTotals({this.input = 0, this.output = 0, this.cacheRead = 0, this.cost, this.unpriced = 0});

  final int input;
  final int output;
  final int cacheRead;
  final UsagePrice? cost;
  double? get cny => cost == null ? null : cost!.hit + cost!.miss + cost!.out;
  final int unpriced;

  UsageTotals operator +(UsageTotals other) => UsageTotals(
    input: input + other.input,
    output: output + other.output,
    cacheRead: cacheRead + other.cacheRead,
    cost: cost == null && other.cost == null ? null : (
      hit: (cost?.hit ?? 0) + (other.cost?.hit ?? 0),
      miss: (cost?.miss ?? 0) + (other.cost?.miss ?? 0),
      out: (cost?.out ?? 0) + (other.cost?.out ?? 0),
    ),
    unpriced: unpriced + other.unpriced,
  );
}

/// Credits provider-reported replies to their completion day in the device time zone.
class DailyUsageController extends AsyncNotifier<List<DailyUsage>> {
  static const _prefix = 'local_chat_usage_v1.';
  Future<void> _writes = Future.value();

  @override
  Future<List<DailyUsage>> build() async => _read(await SharedPreferences.getInstance());

  Future<void> record(String sessionId, AssistantMessageEvent event) {
    final usage = event.usage;
    if (usage == null || event.seq < 0 || event.time.millisecondsSinceEpoch <= 0) {
      return Future.value();
    }
    final hit = usage.cacheReadTokens ?? 0;
    final miss = usage.inputTokens + (usage.cacheWriteTokens ?? 0);
    if (hit + miss + usage.outputTokens <= 0) return Future.value();

    final source = event.message.source;
    final price = switch ((source.provider, source.model)) {
      (
        'deepseek-official',
        'deepseek-flash' || 'deepseek-v4-flash' || 'deepseek-v4-flash-vision-exp',
      ) => (hit: 0.04, miss: 2.0, out: 8.0),
      ('deepseek-official', 'deepseek-v4-pro') => (hit: 0.30, miss: 9.0, out: 27.0),
      _ => null,
    };
    final factor = (tavernDeepSeekPeak(event.time) ? 1.0 : 0.5) / 1e6;
    final cost = price == null ? null : [
      hit * price.hit * factor,
      miss * price.miss * factor,
      usage.outputTokens * price.out * factor,
    ];

    final local = event.time.toLocal();
    final day = local.toIso8601String().split('T').first;
    final key = '$_prefix$day';
    final id = jsonEncode([sessionId, event.seq, event.time.millisecondsSinceEpoch]);
    final write = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final entries = _entries(prefs.getString(key));
      if (entries.containsKey(id)) return;
      entries[id] = [hit + miss, usage.outputTokens, hit, cost];
      if (!await prefs.setString(key, jsonEncode(entries))) {
        // SharedPreferences updates its in-memory cache before writing to disk.
        await prefs.reload();
        throw StateError('Unable to save daily usage');
      }
      if (ref.mounted) state = AsyncData(_read(prefs));
    });
    _writes = write.catchError((Object error, StackTrace stack) {
      if (ref.mounted) state = AsyncError(error, stack);
    });
    return _writes;
  }

  static Map<String, dynamic> _entries(String? raw) {
    if (raw == null) return {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static List<DailyUsage> _read(SharedPreferences prefs) {
    final keys = prefs.getKeys().where((key) => key.startsWith(_prefix)).toList()
      ..sort((a, b) => b.compareTo(a));
    return [for (final key in keys) _readDay(key.substring(_prefix.length), _entries(prefs.getString(key)))];
  }

  static DailyUsage _readDay(String date, Map<String, dynamic> entries) {
    var peak = const UsageTotals();
    var offPeak = const UsageTotals();
    for (final record in entries.entries) {
      if (record.value case [final int input, final int output, final int cacheRead, final Object? storedCost]) {
        // The existing ledger key includes the completion time in epoch milliseconds.
        if (jsonDecode(record.key) case [String _, int _, final int timestamp]) {
          // Older entries stored only a combined USD estimate.
          final cost = switch (storedCost) {
            [final num hit, final num miss, final num out] =>
              (hit: hit.toDouble(), miss: miss.toDouble(), out: out.toDouble()),
            _ => null,
          };
          final totals = UsageTotals(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cost: cost,
            unpriced: cost == null ? 1 : 0,
          );
          if (tavernDeepSeekPeak(DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true))) {
            peak += totals;
          } else {
            offPeak += totals;
          }
        }
      }
    }
    return DailyUsage(date, peak, offPeak);
  }
}
