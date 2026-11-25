import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_tavern/dsh_tavern.dart' show TavernUsage;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../usage/deepseek_billing_time.dart';
import 'connection_state.dart';

final dailyUsageProvider = AsyncNotifierProvider<DailyUsageController, List<DailyUsage>>(DailyUsageController.new);

class DailyUsage {
  const DailyUsage(this.date, this.peak, this.offPeak, this.legacy);

  final String date;
  final UsageTotals peak;
  final UsageTotals offPeak;
  final UsageTotals legacy;

  UsageTotals get total => peak + offPeak;
}

typedef UsagePrice = ({double hit, double miss, double out});

class UsageTotals {
  const UsageTotals({this.input = 0, this.output = 0, this.cacheRead = 0, this.cost, this.unpriced = 0});

  final int input;
  final int output;
  final int cacheRead;
  final UsagePrice? cost;
  bool get isEmpty => input == 0 && output == 0;
  double? get cny => cost == null ? null : cost!.hit + cost!.miss + cost!.out;
  final int unpriced;

  UsageTotals operator +(UsageTotals other) => UsageTotals(
    input: input + other.input,
    output: output + other.output,
    cacheRead: cacheRead + other.cacheRead,
    cost: cost == null && other.cost == null
        ? null
        : (
            hit: (cost?.hit ?? 0) + (other.cost?.hit ?? 0),
            miss: (cost?.miss ?? 0) + (other.cost?.miss ?? 0),
            out: (cost?.out ?? 0) + (other.cost?.out ?? 0),
          ),
    unpriced: unpriced + other.unpriced,
  );
}

/// Tracks settled requests and keeps existing estimates available by day.
class DailyUsageController extends AsyncNotifier<List<DailyUsage>> {
  static const _prefix = 'local_chat_usage_v1.';
  static const _deletedPrefix = 'local_chat_usage_deleted_before.';
  static const _requestOffset = 'local_chat_usage_request_offset';
  static var _tavernRequest = 0;
  Future<void> _writes = Future.value();
  final _requestJournal = Expando<Future<bool>>();

  @override
  Future<List<DailyUsage>> build() async => _read(await SharedPreferences.getInstance());

  Future<void> syncEngine() {
    final connection = ref.read(activeConnectionProvider).value;
    return _enqueue((prefs) async {
      if (connection?.isLocal != true) return;
      var offset = prefs.getInt(_requestOffset) ?? 0;
      while (ref.mounted) {
        final response = await connection!.client.connection.get(
          '/dsh-go/v1/request-usage',
          query: {'offset': '$offset'},
        );
        if (response.statusCode == 404) return;
        if (response.statusCode != 200) {
          throw DshHttpException(response.statusCode, 'Unable to read model request usage');
        }
        final page = jsonDecode(response.text);
        if (page case {'offset': final int next, 'records': final List<Object?> records}) {
          if (next < offset) {
            if (next != 0 || !await prefs.setInt(_requestOffset, 0)) {
              throw StateError('Invalid model request usage offset');
            }
            return;
          }
          if (next == offset) return;
          final days = <String, Map<String, dynamic>>{};
          for (final item in records) {
            if (item case [
              final String id,
              final int timestamp,
              final String model,
              final int hit,
              final int miss,
              final int output,
            ]) {
              final time = DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);
              final day = _day(time, settled: id.startsWith('v2:'));
              if (_wasDeleted(prefs, day, timestamp)) continue;
              final entries = days.putIfAbsent(day, () => _entries(prefs.getString('$_prefix$day')));
              entries[jsonEncode(['request:$id', 0, timestamp])] = _pricedEntry(
                time,
                hit,
                miss,
                output,
                official: true,
                model: model,
              );
            }
          }
          for (final day in days.entries) {
            await _saveEntries(prefs, '$_prefix${day.key}', day.value);
          }
          if (!await prefs.setInt(_requestOffset, next)) {
            await prefs.reload();
            throw StateError('Unable to save model request usage offset');
          }
          offset = next;
        } else {
          throw StateError('Invalid model request usage response');
        }
      }
    }, preserveOnError: true);
  }

  Future<void> deleteDay(String day) => _enqueue((prefs) async {
    if (!await prefs.setInt('$_deletedPrefix$day', DateTime.now().millisecondsSinceEpoch) ||
        !await prefs.remove('$_prefix$day')) {
      await prefs.reload();
      throw StateError('Unable to delete daily usage');
    }
  });

  Future<void> recordLive(DshClient client, String sessionId, AssistantMessageEvent event) async {
    if (event.message.source.provider == 'deepseek-official') {
      final exists = _requestJournal[client] ??= _hasRequestJournal(client);
      if (await exists) return;
    }
    if (ref.mounted) await record(sessionId, event);
  }

  static Future<bool> _hasRequestJournal(DshClient client) async {
    try {
      final reply = await client.connection.get('/dsh-go/v1/request-usage', query: {'probe': '1'});
      return reply.statusCode != 404;
    } catch (_) {
      // A temporary disconnect leaves the engine's durable journal intact.
      return true;
    }
  }

  Future<void> record(String sessionId, AssistantMessageEvent event) {
    final usage = event.usage;
    if (usage == null || event.seq < 0 || event.time.millisecondsSinceEpoch <= 0) {
      return Future.value();
    }
    final source = event.message.source;
    return _record(
      sessionId: sessionId,
      sequence: event.seq,
      time: event.time,
      hit: usage.cacheReadTokens ?? 0,
      miss: usage.inputTokens + (usage.cacheWriteTokens ?? 0),
      output: usage.outputTokens,
      official: source.provider == 'deepseek-official',
      model: source.model,
    );
  }

  Future<void> recordTavern(Uri endpoint, TavernUsage usage, DateTime time) {
    final input = usage.promptTokens < 0 ? 0 : usage.promptTokens;
    final hit = usage.cacheHitTokens.clamp(0, input).toInt();
    return _record(
      sessionId: 'tavern-v2:${time.microsecondsSinceEpoch}',
      sequence: _tavernRequest++,
      time: time,
      hit: hit,
      miss: input - hit,
      output: usage.completionTokens < 0 ? 0 : usage.completionTokens,
      official: endpoint.scheme == 'https' && endpoint.host == 'api.deepseek.com' && endpoint.port == 443,
      model: usage.model,
    );
  }

  Future<void> _record({
    required String sessionId,
    required int sequence,
    required DateTime time,
    required int hit,
    required int miss,
    required int output,
    required bool official,
    required String? model,
  }) {
    if (hit + miss + output <= 0) return Future.value();
    final day = _day(time, settled: sessionId.startsWith('tavern-v2:'));
    final key = '$_prefix$day';
    final timestamp = time.millisecondsSinceEpoch;
    final id = jsonEncode([sessionId, sequence, timestamp]);
    return _enqueue((prefs) async {
      if (_wasDeleted(prefs, day, timestamp)) return;
      final entries = _entries(prefs.getString(key));
      if (entries.containsKey(id)) return;
      entries[id] = _pricedEntry(time, hit, miss, output, official: official, model: model);
      await _saveEntries(prefs, key, entries);
    });
  }

  static String _day(DateTime time, {required bool settled}) =>
      (settled ? time.toUtc().add(const Duration(hours: 8)) : time.toLocal()).toIso8601String().split('T').first;

  static bool _wasDeleted(SharedPreferences prefs, String day, int timestamp) =>
      timestamp <= (prefs.getInt('$_deletedPrefix$day') ?? 0);

  static List<Object?> _pricedEntry(
    DateTime time,
    int hit,
    int miss,
    int output, {
    required bool official,
    required String? model,
  }) {
    final price = switch ((official, model)) {
      (true, 'deepseek-flash' || 'deepseek-v4-flash' || 'deepseek-v4-flash-vision-exp') => (
        hit: 0.04,
        miss: 2.0,
        out: 8.0,
      ),
      (true, 'deepseek-v4-pro') => (hit: 0.30, miss: 9.0, out: 27.0),
      _ => null,
    };
    final factor = (tavernDeepSeekPeak(time) ? 1.0 : 0.5) / 1e6;
    final cost = price == null
        ? null
        : [hit * price.hit * factor, miss * price.miss * factor, output * price.out * factor];

    return [hit + miss, output, hit, cost];
  }

  static Future<void> _saveEntries(SharedPreferences prefs, String key, Map<String, dynamic> entries) async {
    if (!await prefs.setString(key, jsonEncode(entries))) {
      await prefs.reload();
      throw StateError('Unable to save daily usage');
    }
  }

  Future<void> _enqueue(Future<void> Function(SharedPreferences) action, {bool preserveOnError = false}) {
    final write = _writes.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await action(prefs);
      if (ref.mounted) state = AsyncData(_read(prefs));
    });
    _writes = write.catchError((Object error, StackTrace stack) {
      if (ref.mounted && !preserveOnError) state = AsyncError(error, stack);
    });
    return preserveOnError ? write : _writes;
  }

  static Map<String, dynamic> _entries(String? raw) {
    if (raw == null) return {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static List<DailyUsage> _read(SharedPreferences prefs) {
    final keys = prefs.getKeys().where((key) => key.startsWith(_prefix)).toList()..sort((a, b) => b.compareTo(a));
    final days = <DailyUsage>[];
    for (final key in keys) {
      final day = key.substring(_prefix.length);
      final entries = _entries(prefs.getString(key));
      final cutoff = prefs.getInt('$_deletedPrefix$day');
      if (cutoff != null) {
        entries.removeWhere(
          (id, _) => switch (jsonDecode(id)) {
            [String _, int _, final int time] => time <= cutoff,
            _ => false,
          },
        );
      }
      if (entries.isNotEmpty) days.add(_readDay(day, entries));
    }
    return days;
  }

  static DailyUsage _readDay(String date, Map<String, dynamic> entries) {
    var legacy = const UsageTotals();
    var peak = const UsageTotals();
    var offPeak = const UsageTotals();
    for (final record in entries.entries) {
      if (record.value case [final int input, final int output, final int cacheRead, final Object? storedCost]) {
        // The existing ledger key includes the completion time in epoch milliseconds.
        if (jsonDecode(record.key) case [final String id, int _, final int timestamp]) {
          // Older entries stored only a combined USD estimate.
          final cost = switch (storedCost) {
            [final num hit, final num miss, final num out] => (
              hit: hit.toDouble(),
              miss: miss.toDouble(),
              out: out.toDouble(),
            ),
            _ => null,
          };
          final totals = UsageTotals(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cost: cost,
            unpriced: cost == null ? 1 : 0,
          );
          if (!id.startsWith('request:v2:') && !id.startsWith('tavern-v2:')) {
            legacy += totals;
          } else if (tavernDeepSeekPeak(DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true))) {
            peak += totals;
          } else {
            offPeak += totals;
          }
        }
      }
    }
    return DailyUsage(date, peak, offPeak, legacy);
  }
}
