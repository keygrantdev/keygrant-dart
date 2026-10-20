// Reading the machine id from a scripted system (the SDK contract, section 4;
// adapters.test.ts `nodeFingerprinter`; MachineIdTests.swift). The mountinfo
// and boot-time rules are pinned by the conformance vectors; this pins the
// reads around them.

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/src/core/machine_id.dart';

import '../support/adapters_support.dart';

const _short = Duration(milliseconds: 50);

Future<Map<String, Object?>> _read(ScriptedSource source, [Duration timeout = machineIdTimeout]) async =>
    (await readMachineId(source, timeout)).toJson();

Map<String, Object?> _id(String id) => {'kind': 'id', 'id': id};
const _unavailable = {'kind': 'unavailable'};
const _transient = {'kind': 'transient'};

void main() {
  group('Windows', () {
    test('reads MachineGuid, trimmed', () async {
      expect(await _read(ScriptedSource('win32', guids: [guid])), _id(guid));
      expect(await _read(ScriptedSource('win32', guids: ['  $guid\r\n'])), _id(guid));
    });

    test('has no id when the value is empty, missing or not ours to read', () async {
      expect(await _read(ScriptedSource('win32', guids: ['  '])), _unavailable);
      expect(await _read(ScriptedSource('win32', guids: [const ReadFailure.unavailable()])), _unavailable);
    });

    test('reads a failure for this time only, or any other error, as a read that did not finish', () async {
      expect(await _read(ScriptedSource('win32', guids: [const ReadFailure.transient()])), _transient);
      expect(await _read(ScriptedSource('win32', guids: [StateError('odd')])), _transient);
    });

    test('gives up on a read that never finishes, a little after its bound', () async {
      final started = DateTime.now();
      expect(await _read(ScriptedSource('win32', guids: [hang]), _short), _transient);
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 3)));
    });
  });

  group('macOS', () {
    test("reads IOPlatformUUID through IOKit, and runs no command", () async {
      final source = ScriptedSource('darwin', uuids: [macUuid]);
      expect(await _read(source), _id(macUuid));
      expect(await _read(ScriptedSource('darwin', uuids: ['  padded \n'])), _id('padded'));
      expect(source.runs, isEmpty);
    });

    test('has no id when IOKit answers none or an empty one', () async {
      expect(await _read(ScriptedSource('darwin', uuids: [''])), _unavailable);
      expect(await _read(ScriptedSource('darwin', uuids: ['  '])), _unavailable);
    });

    test('runs /usr/sbin/ioreg when IOKit cannot be asked here, and reads the UUID out of it', () async {
      const output = '+-o J314sAP  <class IOPlatformExpertDevice, id 0x100000110, registered>\n'
          '    {\n      "IOPlatformSerialNumber" = "C02XXXXXXX"\n      "IOPlatformUUID" = "$macUuid"\n    }\n';
      final source = ScriptedSource('darwin', outputs: {'/usr/sbin/ioreg': output});
      expect(await _read(source), _id(macUuid));
      expect(source.runs, [
        ['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'],
      ]);
      expect(await _read(ScriptedSource('darwin', outputs: {'/usr/sbin/ioreg': 'no uuid here'})), _unavailable);
      expect(await _read(ScriptedSource('darwin')), _unavailable);
    });

    test('reads an IOKit read that failed, or never finished, as a read that did not finish', () async {
      expect(await _read(ScriptedSource('darwin', uuids: [const ReadFailure.transient()])), _transient);
      expect(await _read(ScriptedSource('darwin', uuids: [StateError('odd')])), _transient);
      expect(await _read(ScriptedSource('darwin', uuids: [hang]), _short), _transient);
      expect(await _read(ScriptedSource('darwin', outputs: {'/usr/sbin/ioreg': hang}), _short), _transient);
    });
  });

  group('Linux', () {
    test('reads /etc/machine-id, else the D-Bus one, trimmed', () async {
      expect(await _read(ScriptedSource('linux', files: {'/etc/machine-id': 'a1b2c3d4e5f6\n'})), _id('a1b2c3d4e5f6'));
      expect(await _read(ScriptedSource('linux', files: {'/var/lib/dbus/machine-id': 'dbus0001\n'})), _id('dbus0001'));
      final empty = {'/etc/machine-id': '\n', '/var/lib/dbus/machine-id': 'dbus0002'};
      expect(await _read(ScriptedSource('linux', files: empty)), _id('dbus0002'));
      final denied = {'/etc/machine-id': const ReadFailure.unavailable(), '/var/lib/dbus/machine-id': 'dbus0003'};
      expect(await _read(ScriptedSource('linux', files: denied)), _id('dbus0003'));
    });

    test('has no id with neither file, nor on another system', () async {
      expect(await _read(ScriptedSource('linux')), _unavailable);
      expect(await _read(ScriptedSource('freebsd')), _unavailable);
    });

    test('reads a file read that failed this time, or never finished, as a read that did not finish', () async {
      expect(await _read(ScriptedSource('linux', files: {'/etc/machine-id': const ReadFailure.transient()})), _transient);
      expect(await _read(ScriptedSource('linux', files: {'/etc/machine-id': hang}), _short), _transient);
    });

    test('has no id to hold a device to when a memory filesystem holds it', () async {
      const mountinfo = '22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n'
          '29 23 0:25 /machine-id /etc/machine-id ro,relatime shared:5 - tmpfs tmpfs rw\n';
      final files = {'/proc/self/mountinfo': mountinfo, '/etc/machine-id': 'transient-id\n'};
      expect(await _read(ScriptedSource('linux', files: files)), _unavailable);
    });

    test('has no id to hold a device to when the file was written at this boot, by its mtime', () async {
      const btime = 1757000000;
      ScriptedSource booted(int mtime) => ScriptedSource('linux',
          files: {'/etc/machine-id': 'a1b2c3d4e5f6\n', '/proc/stat': 'cpu 1 2 3\nbtime $btime\n'},
          mtimes: {'/etc/machine-id': mtime});
      expect(await _read(booted(btime * 1000 + 3000)), _unavailable);
      expect(await _read(booted(btime * 1000 - bootSlackMs)), _unavailable);
      expect(await _read(booted(btime * 1000 - bootSlackMs - 1)), _id('a1b2c3d4e5f6'));
      // No mtime this source can tell: the id as always.
      expect(await _read(ScriptedSource('linux', files: {'/etc/machine-id': 'a1b2c3d4e5f6\n'})), _id('a1b2c3d4e5f6'));
    });
  });

  test('bounds a read at 2 s for a status and 10 s for an activation or a trial start', () {
    expect(machineIdTimeout, const Duration(seconds: 2));
    expect(activateMachineIdTimeout, const Duration(seconds: 10));
    expect(bootSlackMs, 5000);
  });
}
