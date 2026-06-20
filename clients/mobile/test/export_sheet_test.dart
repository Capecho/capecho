import 'dart:convert';
import 'dart:typed_data';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capecho_mobile/theme.dart';
import 'package:capecho_mobile/word_book/export_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `GET /export` returns the raw CSV text (not JSON); everything else is an empty `/words` list. (The
/// Anki `.apkg` path runs the real SQLite builder, covered by app-core's anki_deck_test — here we cover
/// the mobile sheet wiring via the no-SQLite CSV path + the share seam.)
class _ExportTransport implements HttpTransport {
  String csv = 'Word,Context,Definition,Language\nserendipity,a happy accident,,en\n';

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    final path = Uri.parse(r.url).path;
    if (path.endsWith('/export')) return TransportResponse(statusCode: 200, body: csv);
    return TransportResponse(statusCode: 200, body: jsonEncode(const {'words': []}));
  }
}

CapechoApi _api(_ExportTransport t) =>
    CapechoApi(baseUrl: 'https://api.test', transport: t)..restoreToken('test-session');

void main() {
  testWidgets('CSV export builds the file and hands it to the share seam', (tester) async {
    final c = WordBookController(api: _api(_ExportTransport()));
    addTearDown(c.dispose);
    String? sharedName;
    Uint8List? sharedBytes;
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(
          body: ExportSheet(
            controller: c,
            totalCount: 1,
            shareFile: ({required String name, required Uint8List bytes}) async {
              sharedName = name;
              sharedBytes = bytes;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('CSV')); // switch off the default Anki format
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();

    // A real `.csv` file carrying the backend CSV reached the share sheet; the "exported" screen shows.
    expect(sharedName, 'capecho-wordbook.csv');
    expect(utf8.decode(sharedBytes!), contains('serendipity'));
    expect(find.text('Word Book exported'), findsOneWidget);
  });

  testWidgets('dismissing the share sheet returns to the form (no "exported" screen)', (
    tester,
  ) async {
    final c = WordBookController(api: _api(_ExportTransport()));
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(
          body: ExportSheet(
            controller: c,
            totalCount: 1,
            // false = the user dismissed the OS share sheet.
            shareFile: ({required String name, required Uint8List bytes}) async => false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('CSV'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();

    expect(find.text('Word Book exported'), findsNothing);
    expect(find.text('Export CSV'), findsOneWidget); // still on the form
  });
}
