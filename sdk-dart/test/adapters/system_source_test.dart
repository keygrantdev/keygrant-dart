// The real system the machine id is read from (system_source.dart,
// windows_registry.dart): the registry on this host when it is Windows, the
// commands and files it runs and reads, IOKit through the plugin's bridge,
// and this machine's host names as Node names them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/src/core/identity.dart';
import 'package:keygrant/src/core/machine_id.dart';
import 'package:keygrant/src/core/platform_bridge.dart';
import 'package:keygrant/src/core/system_source.dart';
import 'package:keygrant/src/core/windows_registry.dart';

import '../support/adapters_support.dart';
import '../support/storage_support.dart' show inTemp, sep;

final _guidShape = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
const _second = Duration(seconds: 5);
final _notWindows = Platform.isWindows ? null : 'reads the Windows registry';

Matcher _failure({required bool unavailable}) =>
    isA<ReadFailure>().having((f) => f.unavailable, 'unavailable', unavailable);

void main() {
  group('on Windows', () {
    test('reads MachineGuid from the registry API: a GUID, the one reg.exe prints from the 64-bit view', () async {
      final value = readWindowsMachineGuid();
      expect(value, matches(_guidShape));
      final reg = await Process.run('reg', [r'query', r'HKLM\SOFTWARE\Microsoft\Cryptography', '/v', 'MachineGuid', '/reg:64']);
      expect(reg.stdout as String, contains(value));
    }, skip: _notWindows);

    test('reads this machine as an id through the real source', () async {
      final reading = await readMachineId(SystemMachineIdSource(bridge: const NoPlatformBridge()));
      expect(reading.toJson(), {'kind': 'id', 'id': readWindowsMachineGuid()});
      expect(await SystemMachineIdSource().windowsMachineGuid(machineIdTimeout), readWindowsMachineGuid());
    }, skip: _notWindows);
  });

  test("names this system and architecture as Node's process.platform and process.arch do", () {
    final platform = nodePlatform();
    expect(platform, {'windows': 'win32', 'macos': 'darwin', 'linux': 'linux'}[Platform.operatingSystem] ?? Platform.operatingSystem);
    expect(nodeArch(), isIn(['x64', 'arm64', 'ia32', 'arm', 'riscv64']));
    expect(SystemMachineIdSource(bridge: const NoPlatformBridge()).platform, platform);
  });

  test("reads this machine's host names: the host as the system holds it, with Node's names", () {
    final host = hostNames()!;
    expect(host.host, Platform.localHostname);
    expect((host.platform, host.arch), (nodePlatform(), nodeArch()));
    expect(hostNamesFingerprint(host), fp('${Platform.localHostname}|${nodePlatform()}|${nodeArch()}'));
  });

  test('reads the host names Node reads on this machine, when Node is here to ask', () async {
    final ProcessResult node;
    try {
      node = await Process.run(
          'node', ['-e', "const os = require('os'); console.log([os.hostname(), process.platform, process.arch].join('|'))"]);
    } on ProcessException {
      return markTestSkipped('no node on this machine');
    }
    if (node.exitCode != 0) return markTestSkipped('no node on this machine');
    final host = hostNames()!;
    expect('${host.host}|${host.platform}|${host.arch}', (node.stdout as String).trim());
  });

  group('IOKit through the bridge', () {
    test('is what the plugin answers to machineId, asked with no arguments', () async {
      final bridge = answering(macUuid);
      expect(await SystemMachineIdSource(bridge: bridge).platformUuid(_second), macUuid);
      expect(bridge.called, [[NativeMethod.machineId, const <String, Object?>{}]]);
    });

    test('is an empty id (none to read) when the plugin answers none', () async {
      expect(await SystemMachineIdSource(bridge: answering(null)).platformUuid(_second), '');
      expect(await SystemMachineIdSource(bridge: answering(42)).platformUuid(_second), '');
    });

    test('is not asked of a run with no channel: null, so ioreg is run', () async {
      expect(await SystemMachineIdSource(bridge: const NoPlatformBridge()).platformUuid(_second), isNull);
      expect(await SystemMachineIdSource(bridge: FakeBridge()).platformUuid(_second), isNull);
    });

    test('is a read that did not finish when the plugin fails', () async {
      final failing = FakeBridge(answer: (_, __) => throw Exception('IOKit said no'));
      await expectLater(SystemMachineIdSource(bridge: failing).platformUuid(_second), throwsA(_failure(unavailable: false)));
    });

    test('uses the bridge the plugin set when given none', () async {
      final before = PlatformBridge.instance;
      addTearDown(() => PlatformBridge.instance = before);
      final bridge = answering(macUuid);
      PlatformBridge.instance = bridge;
      expect(await SystemMachineIdSource().platformUuid(_second), macUuid);
      expect(bridge.calls, hasLength(1));
    });
  });

  group('commands', () {
    final echo = Platform.isWindows ? ('cmd', ['/c', 'echo hello']) : ('sh', ['-c', 'echo hello']);
    final failing = Platform.isWindows ? ('cmd', ['/c', 'exit 3']) : ('sh', ['-c', 'exit 3']);
    final slow = Platform.isWindows ? ('ping', ['-n', '30', '127.0.0.1']) : ('sleep', ['30']);

    test("answers a command's standard output", () async {
      final (command, args) = echo;
      expect((await SystemMachineIdSource().run(command, args, _second)).trim(), 'hello');
    });

    test('has nothing to read from a command that ran and said no, or is not there', () async {
      final (command, args) = failing;
      await expectLater(SystemMachineIdSource().run(command, args, _second), throwsA(_failure(unavailable: true)));
      await expectLater(SystemMachineIdSource().run('keygrant-no-such-command', const [], _second), throwsA(_failure(unavailable: true)));
    });

    test('ends a command that outlives its bound: a read that did not finish, promptly', () async {
      final (command, args) = slow;
      final started = DateTime.now();
      await expectLater(
          SystemMachineIdSource().run(command, args, const Duration(milliseconds: 200)), throwsA(_failure(unavailable: false)));
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
    });
  });

  group('files', () {
    test("answers a file's text, and its mtime", () => inTemp((dir) async {
          final path = '$dir${sep}machine-id';
          File(path).writeAsStringSync('a1b2c3d4e5f6\n');
          final source = SystemMachineIdSource();
          expect(await source.readFile(path), 'a1b2c3d4e5f6\n');
          final mtime = await source.mtimeMs(path)!;
          expect(mtime, File(path).lastModifiedSync().millisecondsSinceEpoch);
        }));

    test('has nothing to read from a file that is not there', () => inTemp((dir) async {
          final path = '$dir${sep}missing';
          await expectLater(SystemMachineIdSource().readFile(path), throwsA(_failure(unavailable: true)));
          await expectLater(SystemMachineIdSource().mtimeMs(path)!, throwsA(_failure(unavailable: true)));
        }));
  });
}
