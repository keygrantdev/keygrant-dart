// The desktop default fingerprinter (the SDK contract, section 4;
// adapters.test.ts `nodeFingerprinter`; DefaultFingerprinterTests.swift): the
// machine id hashed, the host name's as its alternate or its fallback, a
// settled read kept and a transient one never.

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/identity.dart';
import 'package:keygrant/src/core/machine_id.dart';

import '../support/adapters_support.dart';

const _bound = Duration(seconds: 1);

DesktopFingerprinter _over(ScriptedSource source, [HostNames? Function()? host]) =>
    DesktopFingerprinter(source: source, host: host ?? () => names);

Future<Map<String, Object?>> _identify(DesktopFingerprinter f) async => (await f.identify(_bound)).toJson();

void main() {
  test('hashes the machine id, so the raw id never leaves the machine', () async {
    final fingerprint = await _over(ScriptedSource('win32', guids: [guid])).get();
    expect(fingerprint, fp('machine-id|$guid'));
    expect(fingerprint, isNot(contains('3f2504e0')));
    expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test("offers the host-name fingerprint as an alternate beside the machine id's", () async {
    expect(await _identify(_over(ScriptedSource('win32', guids: [guid]))), {
      'fingerprint': machineFp,
      'kind': 'machine',
      'alternates': [hostFp],
    });
  });

  test('composes the host-name fingerprint from the host, the platform and the arch as Node names them', () {
    expect(hostFp, fp('studio|win32|x64'));
    expect(hostNamesFingerprint(null), fp('unknown-host'));
  });

  test('survives a rename: the fingerprint follows the machine id, not the host name', () async {
    final before = await _over(ScriptedSource('linux', files: {'/etc/machine-id': 'same-machine'})).get();
    const renamed = HostNames(host: 'renamed', platform: 'linux', arch: 'x64');
    final after = await _over(ScriptedSource('linux', files: {'/etc/machine-id': 'same-machine'}), () => renamed).get();
    expect(after, before);
    expect(before, isNot(hostFp));
  });

  test('falls back to the host name, for good, when the machine has no id to read', () async {
    for (final source in [
      ScriptedSource('win32'),
      ScriptedSource('darwin', uuids: ['']),
      ScriptedSource('linux'),
      ScriptedSource('freebsd'),
    ]) {
      final fingerprinter = _over(source);
      expect(await fingerprinter.get(), hostFp);
      // Settled: kept, with no host-name alternate besides itself.
      expect(await _identify(fingerprinter), {'fingerprint': hostFp, 'kind': 'hostname', 'alternates': <String>[]});
      expect(source.reads.where((r) => r == 'guid' || r == 'uuid' || r.startsWith('file /etc')).length, lessThanOrEqualTo(1));
    }
  });

  test('gives NO fingerprint for a read that did not finish, the host name only as an alternate', () async {
    for (final source in [
      ScriptedSource('win32', guids: [const ReadFailure.transient()]),
      ScriptedSource('darwin', uuids: [StateError('odd')]),
      ScriptedSource('linux', files: {'/etc/machine-id': const ReadFailure.transient()}),
    ]) {
      expect(await _identify(_over(source)), {'fingerprint': null, 'alternates': [hostFp]});
    }
  });

  test('reads again after a read that did not finish, and keeps the id once it has it', () async {
    final flaky = ScriptedSource('win32', guids: [const ReadFailure.transient(), guid]);
    final fingerprinter = _over(flaky);
    expect((await fingerprinter.identify(_bound)).fingerprint, isNull);
    expect((await fingerprinter.identify(_bound)).fingerprint, machineFp);
    expect((await fingerprinter.identify(_bound)).fingerprint, machineFp);
    expect(flaky.reads, ['guid', 'guid']);
  });

  test("takes the host name's as of each call, the id kept", () async {
    var host = names;
    final fingerprinter = _over(ScriptedSource('win32', guids: [guid]), () => host);
    expect((await fingerprinter.identify(_bound)).alternates, [hostFp]);
    host = const HostNames(host: 'renamed', platform: 'win32', arch: 'x64');
    final identity = await fingerprinter.identify(_bound);
    expect(identity.fingerprint, machineFp);
    expect(identity.alternates, [fp('renamed|win32|x64')]);
  });

  test('hashes host names that cannot be read as unknown-host', () async {
    final fingerprinter = _over(ScriptedSource('win32', guids: [guid]), () => null);
    expect((await fingerprinter.identify(_bound)).alternates, [fp('unknown-host')]);
    expect(await _over(ScriptedSource('linux'), () => null).get(), fp('unknown-host'));
  });

  test('get() throws when the id cannot be read, rather than answer a stand-in', () async {
    await expectLater(_over(ScriptedSource('win32', guids: [const ReadFailure.transient()])).get(), throwsStateError);
  });

  test('gives no fingerprint once its time box is out when the read never finishes', () async {
    final started = DateTime.now();
    final identity = await _over(ScriptedSource('win32', guids: [hang])).identify(const Duration(milliseconds: 50));
    expect(identity.fingerprint, isNull);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 3)));
  });

  test('keeps a fingerprinter of its own source apart from another', () async {
    final source = ScriptedSource('win32', guids: [guid]);
    await _over(source).identify(_bound);
    await _over(source).identify(_bound);
    expect(source.reads, ['guid', 'guid']);
  });

  test("reads this machine's id once for the whole process, a 64-hex fingerprint", () async {
    final first = await DesktopFingerprinter().identify(machineIdTimeout);
    final second = await DesktopFingerprinter().identify(machineIdTimeout);
    expect(first.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(second.toJson(), first.toJson());
    expect(await DesktopFingerprinter().get(), first.fingerprint);
  });
}
