// Run on a device: the plugin's native side answers this device's id, which
// the default fingerprinter reads (the SDK contract, sections 4 and 4.1).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keygrant/keygrant.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the default fingerprinter reads this device\'s id', (tester) async {
    final Fingerprinter fingerprinter =
        Platform.isIOS || Platform.isAndroid ? MobileFingerprinter(product: 'example') : DesktopFingerprinter();
    final identity = await fingerprinter.identify(const Duration(seconds: 10))!;
    expect(identity.fingerprint, isNotNull);
    if (Platform.isIOS || Platform.isAndroid) expect(identity.alternates, isEmpty);
  });
}
