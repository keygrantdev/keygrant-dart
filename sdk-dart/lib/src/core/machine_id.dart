/// The operating system's own id for this machine on Windows, macOS and Linux
/// (the SDK contract, section 4; machine-id.ts), which the default
/// fingerprinter hashes. A read is an id, `unavailable` (this machine has no
/// usable id, now or on the next try) or `transient` (could not tell this
/// time: a timeout, a failed command, a busy file), which gives no fingerprint
/// and is not kept, so a slow read never stands in for the id.
library;

import 'dart:async';

import 'text.dart';

/// How long `status()` may spend reading the machine id.
const Duration machineIdTimeout = Duration(seconds: 2);

/// How long `activate()` and `startTrial()` may: a person is waiting.
const Duration activateMachineIdTimeout = Duration(seconds: 10);

/// How far before the boot time an id may have been written and still count
/// as written at this boot (ms).
const int bootSlackMs = 5000;

/// What reading the machine id gave.
sealed class MachineIdReading {
  const MachineIdReading();

  Map<String, Object?> toJson();
}

/// The machine's id.
final class MachineIdFound extends MachineIdReading {
  const MachineIdFound(this.id);
  final String id;
  @override
  Map<String, Object?> toJson() => {'kind': 'id', 'id': id};
}

/// There is no id to read, and there will not be on the next try.
final class MachineIdUnavailable extends MachineIdReading {
  const MachineIdUnavailable();
  @override
  Map<String, Object?> toJson() => {'kind': 'unavailable'};
}

/// The read did not finish: no fingerprint this time.
final class MachineIdTransient extends MachineIdReading {
  const MachineIdTransient();
  @override
  Map<String, Object?> toJson() => {'kind': 'transient'};
}

/// Why a read failed: for good ([unavailable]: missing, not ours to read, a
/// command that ran and said no) or this time only.
final class ReadFailure implements Exception {
  const ReadFailure.unavailable() : unavailable = true;
  const ReadFailure.transient() : unavailable = false;
  final bool unavailable;

  @override
  String toString() => unavailable ? 'ReadFailure: unavailable' : 'ReadFailure: transient';
}

/// Where the machine id is read from: the real system, or a stand-in in tests.
/// Each read throws a [ReadFailure] when it fails, or anything else, which is
/// read as `transient`.
abstract class MachineIdSource {
  /// As Node names it: `win32`, `darwin`, `linux`, or another.
  String get platform;

  /// Windows: the `MachineGuid` value under `HKLM\SOFTWARE\Microsoft\Cryptography`,
  /// read in the 64-bit registry view.
  Future<String> windowsMachineGuid(Duration timeout);

  /// macOS: `IOPlatformUUID` read through IOKit, or null when this source
  /// cannot read it so (then `ioreg` is run).
  Future<String?> platformUuid(Duration timeout);

  /// A command's standard output.
  Future<String> run(String command, List<String> args, Duration timeout);

  /// A file's text.
  Future<String> readFile(String path);

  /// When a file's content was last written (ms); null when this source cannot tell.
  Future<num>? mtimeMs(String path);
}

const String _ioreg = '/usr/sbin/ioreg';
const List<String> _linuxIdFiles = ['/etc/machine-id', '/var/lib/dbus/machine-id'];
const String _machineIdPath = '/etc/machine-id';
const Set<String> _inMemory = {'tmpfs', 'ramfs'};

/// This machine's id, or why there is none. Never throws, and never takes much
/// longer than `timeout`.
Future<MachineIdReading> readMachineId(MachineIdSource source, [Duration timeout = machineIdTimeout]) async {
  try {
    final bound = timeout + const Duration(milliseconds: 500);
    if (source.platform == 'win32') return _idIn(await source.windowsMachineGuid(timeout).timeout(bound));
    if (source.platform == 'darwin') return await _macPlatformUuid(source, timeout, bound);
    // An id on a filesystem in memory is new every boot: no id to hold a device to.
    if (await _transientMachineId(source, timeout)) return const MachineIdUnavailable();
    for (final path in _linuxIdFiles) {
      final reading = await _fromFile(source, path, timeout);
      if (reading is MachineIdUnavailable) continue;
      if (reading is MachineIdFound && await _writtenThisBoot(source, path, timeout)) return const MachineIdUnavailable();
      return reading;
    }
    return const MachineIdUnavailable();
  } catch (error) {
    return _failureKind(error);
  }
}

Future<MachineIdReading> _macPlatformUuid(MachineIdSource source, Duration timeout, Duration bound) async {
  final uuid = await source.platformUuid(timeout).timeout(bound);
  if (uuid != null) return _idIn(uuid);
  final out = await source.run(_ioreg, const ['-rd1', '-c', 'IOPlatformExpertDevice'], timeout).timeout(bound);
  return _idIn(RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"').firstMatch(out)?.group(1));
}

MachineIdReading _idIn(String? value) {
  final id = value == null ? '' : jsTrim(value);
  return id.isNotEmpty ? MachineIdFound(id) : const MachineIdUnavailable();
}

MachineIdReading _failureKind(Object error) =>
    error is ReadFailure && error.unavailable ? const MachineIdUnavailable() : const MachineIdTransient();

Future<bool> _transientMachineId(MachineIdSource source, Duration timeout) async {
  try {
    final fstype = machineIdFilesystem(await source.readFile('/proc/self/mountinfo').timeout(timeout));
    return fstype != null && _inMemory.contains(fstype);
  } catch (_) {
    return false;
  }
}

Future<MachineIdReading> _fromFile(MachineIdSource source, String path, Duration timeout) async {
  try {
    return _idIn(await source.readFile(path).timeout(timeout));
  } catch (error) {
    return _failureKind(error);
  }
}

/// Whether the id file was written at this boot: its mtime no older than the
/// boot time (`btime` in `/proc/stat`) less [bootSlackMs]. False when either
/// cannot be read. Never throws.
Future<bool> _writtenThisBoot(MachineIdSource source, String path, Duration timeout) async {
  try {
    final mtime = source.mtimeMs(path);
    if (mtime == null) return false;
    final [written as num, procStat as String] = await Future.wait<Object>([
      mtime.timeout(timeout),
      source.readFile('/proc/stat').timeout(timeout),
    ]);
    final btime = RegExp(r'^btime (\d+)$', multiLine: true).firstMatch(procStat)?.group(1);
    if (btime == null) return false;
    return written >= int.parse(btime) * 1000 - bootSlackMs;
  } catch (_) {
    return false;
  }
}

/// The type of the filesystem /etc/machine-id is on, from mountinfo: the mount
/// whose mount point is the longest prefix of the path on a path boundary; of
/// several at that point, the one on top. Null when no line can be read so.
String? machineIdFilesystem(String mountinfo) {
  final mounts = <_Mount>[];
  for (final line in mountinfo.split('\n')) {
    final fields = line.split(' ');
    final separator = fields.length > 6 ? fields.indexOf('-', 6) : -1;
    if (fields.length < 5 || separator <= 0 || separator + 1 >= fields.length) continue;
    final point = fields[4].replaceAllMapped(RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)));
    if (point == _machineIdPath || point == '/' || _machineIdPath.startsWith('$point/')) {
      mounts.add(_Mount(fields[0], fields[1], point, fields[separator + 1]));
    }
  }
  if (mounts.isEmpty) return null;
  final deepest = mounts.map((m) => m.point.length).reduce((a, b) => a > b ? a : b);
  return _topMount([for (final m in mounts) if (m.point.length == deepest) m]).fstype;
}

final class _Mount {
  const _Mount(this.id, this.parent, this.point, this.fstype);
  final String id;
  final String parent;
  final String point;
  final String fstype;
}

_Mount _topMount(List<_Mount> atPoint) {
  final tops = [
    for (final m in atPoint)
      if (!atPoint.any((other) => !identical(other, m) && other.parent == m.id)) m,
  ];
  return tops.length == 1 ? tops.single : atPoint.last;
}
