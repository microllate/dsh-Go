import 'dart:async';

import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, a piece of the reply every 20 ms, counting the pieces.
class _Counted extends PreviewTavern {
  _Counted() : super(tick: const Duration(milliseconds: 20));

  int pieces = 0;
  int pathReads = 0;
  int sends = 0;
  Completer<void>? sendGate;

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) {
    pathReads++;
    return super.path(chatId, limit: limit, beforeNodeId: beforeNodeId);
  }

  @override
  Stream<TavernEvent> send(String chatId, String text) {
    sends++;
    final gate = sendGate;
    final events = gate == null
        ? super.send(chatId, text)
        : Stream.fromFuture(gate.future).asyncExpand((_) => super.send(chatId, text));
    return events.map((event) {
      if (event is TavernTextDelta) pieces++;
      return event;
    });
  }
}

Future<void> _open(
  WidgetTester tester,
  PreviewTavern tavern, {
  Map<String, Object> prefs = const {},
  Size size = const Size(390, 844),
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tavernProvider.overrideWith((ref) => tavern)],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: TavernChatPage(chatId: chat),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Sends a line and lets the whole reply arrive, a frame for each piece;
/// returns how many times a message row was rebuilt meanwhile.
Future<int> _sendCountingRows(WidgetTester tester) async {
  var rows = 0;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget.runtimeType.toString() == '_MessageRow') rows++;
  };
  addTearDown(() => debugOnRebuildDirtyWidget = null);
  await tester.enterText(find.byType(TextField), '外面怎么了？');
  await tester.pump();
  await tester.tap(find.byIcon(AppIcons.send));
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pumpAndSettle();
  debugOnRebuildDirtyWidget = null;
  return rows;
}

void main() {
  testWidgets('the visible user row stays in place when its saved message arrives', (tester) async {
    final gate = Completer<void>();
    final tavern = _Counted()..sendGate = gate;
    await _open(tester, tavern);
    final input = find.byType(TextField);
    const text = '外面怎么了？\n\n**真的没事？**';
    final userText = find.textContaining('外面怎么了？', findRichText: true);
    final userRow = find.ancestor(
      of: userText,
      matching: find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_MessageRow'),
    );
    await tester.enterText(input, text);
    await tester.pump();

    await tester.tap(find.byIcon(AppIcons.send));
    expect(tavern.sends, 0);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);

    await tester.pump();
    expect(find.byIcon(AppIcons.stopGenerating), findsOneWidget);
    expect(tavern.sends, 1);
    expect(userText, findsOneWidget);
    final initialElement = tester.element(userRow);
    final initialRect = tester.getRect(userRow);
    final readsBeforeSave = tavern.pathReads;

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(tavern.pathReads, greaterThan(readsBeforeSave));
    expect(userText, findsOneWidget);
    expect(tester.element(userRow), same(initialElement));
    final actualRect = tester.getRect(userRow);
    expect(actualRect.left, closeTo(initialRect.left, 0.01));
    expect(actualRect.top, closeTo(initialRect.top, 0.01));
    expect(actualRect.right, closeTo(initialRect.right, 0.01));
    expect(actualRect.bottom, closeTo(initialRect.bottom, 0.01));

    await tester.pumpAndSettle();
    expect(userText, findsOneWidget);
  });

  testWidgets('a reply that grows past the top shades the header, though nothing was scrolled', (tester) async {
    // Short enough that the reply outgrows it; the list stays at its newest end.
    await _open(tester, _Counted(), size: const Size(390, 420));
    double shade() => tester.widget<BotChatHeader>(find.byType(BotChatHeader)).scrolledUnder!.value;
    expect(shade(), 0);

    await _sendCountingRows(tester);
    expect(find.textContaining('地下室'), findsOneWidget);
    expect(shade(), greaterThan(0));
  });

  testWidgets('a piece of the reply rebuilds the reply, not the messages above it', (tester) async {
    final tavern = _Counted();
    await _open(tester, tavern);
    final rows = await _sendCountingRows(tester);

    expect(find.textContaining('地下室'), findsOneWidget); // the whole reply arrived
    expect(tavern.pieces, greaterThan(10));
    // The rows rebuild when the turn starts, settles and ends, not once per
    // piece (two rows on screen, a rebuild each piece, would be twice the pieces).
    expect(rows, lessThan(tavern.pieces));
  });

  testWidgets('turn completion and its path notification share one transcript read', (tester) async {
    final tavern = _Counted();
    await _open(tester, tavern);
    tavern.pathReads = 0;

    await _sendCountingRows(tester);

    expect(find.textContaining('地下室'), findsOneWidget);
    // One read at reply start and one when the completed reply is committed.
    expect(tavern.pathReads, 2);
  });

  testWidgets('in 视觉小说 the page being written still follows the reply', (tester) async {
    final tavern = _Counted();
    await _open(tester, tavern, prefs: {'tavern.layout': 'visualNovel'});
    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    // Part way: the reply's first page is there, still being written.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.textContaining('这个问题', findRichText: true), findsWidgets);
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('地下室', findRichText: true), findsWidgets);
  });
}
