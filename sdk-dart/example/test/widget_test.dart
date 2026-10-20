// The example's panel over a licence with no network and no stored state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant_example/main.dart';

final class _Memory extends StorageAdapter {
  StoredState? stored;
  @override
  Future<StoredState?> read({bool readOnly = false}) async => stored;
  @override
  Future<void> write(StoredState state) async => stored = state;
}

final class _Offline implements HttpAdapter {
  @override
  Future<HttpResponse> post(String url, Map<String, Object?> body, {required Duration timeout}) async =>
      throw Exception('offline');
}

final class _Fixed extends Fingerprinter {
  @override
  Future<String> get() async => 'fp-example';
}

void main() {
  testWidgets('shows the status, and the restore asks for a code', (tester) async {
    final license = KeyGrantLicense(LicenseConfig(
      product: 'example',
      apiBaseUrl: 'https://api.test',
      publicJwk: const {'kty': 'OKP', 'crv': 'Ed25519', 'x': '11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo'},
      adapters: LicenseAdapters(storage: _Memory(), http: _Offline(), fingerprinter: _Fixed()),
    ));
    await tester.pumpWidget(ExampleApp(license: license));
    await tester.pumpAndSettle();
    expect(find.text('Status: unlicensed '), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'ada@example.com');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    expect(find.text('Could not send a code: network'), findsOneWidget);
  });
}
