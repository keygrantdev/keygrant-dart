// The KeyGrant plugin's example: the licence's status, a trial, a typed key,
// and the restore an App Store build offers instead of a typed key (a code
// mailed to the address the key was sold to). Replace the product, the API
// base and the public keys with your product's before you run it.

import 'package:flutter/material.dart';
import 'package:keygrant/keygrant.dart';

/// Your product's slug and its public keys, the `keys` of
/// `GET https://api.keygrant.dev/v1/products/<product>/pubkey`. The key below
/// is RFC 8037's example key, which signs nothing of yours.
const _product = 'your-product';
const _publicJwk = {'kty': 'OKP', 'crv': 'Ed25519', 'x': '11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo'};

void main() {
  final license = KeyGrantLicense(const LicenseConfig(
    product: _product,
    apiBaseUrl: 'https://api.keygrant.dev',
    publicJwk: _publicJwk,
    major: 1,
  ));
  runApp(ExampleApp(license: license));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.license});

  final KeyGrantLicense license;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'KeyGrant example',
        home: Scaffold(
          appBar: AppBar(title: const Text('KeyGrant example')),
          body: LicensePanel(license: license),
        ),
      );
}

/// The licence's status and the calls that change it.
class LicensePanel extends StatefulWidget {
  const LicensePanel({super.key, required this.license});

  final KeyGrantLicense license;

  @override
  State<LicensePanel> createState() => _LicensePanelState();
}

class _LicensePanelState extends State<LicensePanel> {
  LicenseStatus? _status;
  String _message = '';
  bool _codeSent = false;
  final _key = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();

  KeyGrantLicense get _license => widget.license;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final status = await _license.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _say(String message) async {
    await _refresh();
    if (mounted) setState(() => _message = message);
  }

  Future<void> _startTrial() async {
    final status = await _license.startTrial();
    await _say('Trial: ${status.state.wire}');
  }

  Future<void> _activate() async {
    final result = await _license.activate(_key.text);
    await _say(switch (result) {
      Activated() => 'Activated.',
      ActivateFailed(:final error) => 'Not activated: ${error.wire}',
    });
  }

  /// Restore, step one: a code mailed to the address the key was sold to.
  Future<void> _sendCode() async {
    final result = await _license.pickUp(_email.text);
    setState(() => _codeSent = result.ok);
    await _say(switch (result) {
      PickUpCodeSent() => 'If that address bought a key, a code is on its way.',
      PickUpSendFailed(:final error) => 'Could not send a code: ${error.wire}',
    });
  }

  /// Restore, step two: the code, and the key that fits this build activated.
  Future<void> _restore() async {
    final result = await _license.restoreByEmail(_email.text, _code.text);
    await _say(switch (result) {
      Restored() => 'Restored.',
      RestoreFailed(:final error) => 'Not restored: ${error.wire}',
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(status == null ? 'Reading the licence...' : 'Status: ${status.state.wire} ${status.reason?.wire ?? ''}'),
        if (status?.trialDaysLeft != null) Text('Trial days left: ${status!.trialDaysLeft}'),
        if (_message.isNotEmpty) Text(_message),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: _startTrial, child: const Text('Start trial')),
        const Divider(),
        TextField(controller: _key, decoration: const InputDecoration(labelText: 'Licence key')),
        ElevatedButton(onPressed: _activate, child: const Text('Activate')),
        const Divider(),
        const Text('Bought on the web? Restore your purchase by email.'),
        TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email')),
        ElevatedButton(onPressed: _sendCode, child: const Text('Send code')),
        if (_codeSent) ...[
          TextField(controller: _code, decoration: const InputDecoration(labelText: 'Code')),
          ElevatedButton(onPressed: _restore, child: const Text('Restore')),
        ],
      ],
    );
  }
}
