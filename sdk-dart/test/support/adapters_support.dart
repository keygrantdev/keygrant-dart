// What the adapter tests share (the reference's adapters.test.ts, MachineIdTests.swift):
// a machine-id source scripted read by read, and a platform bridge that
// answers as a test says.

import 'dart:async';

import 'package:keygrant/src/core/identity.dart';
import 'package:keygrant/src/core/keys.dart';
import 'package:keygrant/src/core/machine_id.dart';
import 'package:keygrant/src/core/platform_bridge.dart';

const String guid = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
const String macUuid = '564D8A1C-3F6E-4E3B-9F2A-1B2C3D4E5F60';
const HostNames names = HostNames(host: 'studio', platform: 'win32', arch: 'x64');
final String hostFp = hostNamesFingerprint(names);
final String machineFp = machineFingerprint(guid);

/// A read that never finishes.
const Object hang = _Hang();

final class _Hang {
  const _Hang();
}

/// One scripted answer: a value, or a throw of a [ReadFailure] or any other
/// error, or [hang].
Future<T> _answer<T>(Object? scripted) {
  if (identical(scripted, hang)) return Completer<T>().future;
  if (scripted is ReadFailure || scripted is Exception || scripted is Error) return Future.error(scripted!);
  return Future.value(scripted as T);
}

/// The answer at `index` of `script`, the last one repeated.
Object? _at(List<Object?> script, int index) => script[index < script.length ? index : script.length - 1];

/// A stand-in system: the registry value and IOKit's answers in order (the
/// last repeated); what each command prints and each file holds (or how it
/// fails); each file's mtime. Anything not named is not there.
final class ScriptedSource extends MachineIdSource {
  ScriptedSource(
    this.platform, {
    this.guids = const [ReadFailure.unavailable()],
    this.uuids = const [null],
    this.outputs = const {},
    this.files = const {},
    this.mtimes = const {},
  });

  @override
  final String platform;
  final List<Object?> guids;
  final List<Object?> uuids;
  final Map<String, Object> outputs;
  final Map<String, Object> files;
  final Map<String, num> mtimes;

  /// Every read made, in order: `guid`, `uuid`, a command, or `file <path>`.
  final List<String> reads = [];
  final List<List<String>> runs = [];

  int _count(String what) => reads.where((r) => r == what).length;

  @override
  Future<String> windowsMachineGuid(Duration timeout) {
    reads.add('guid');
    return _answer(_at(guids, _count('guid') - 1));
  }

  @override
  Future<String?> platformUuid(Duration timeout) {
    reads.add('uuid');
    return _answer(_at(uuids, _count('uuid') - 1));
  }

  @override
  Future<String> run(String command, List<String> args, Duration timeout) {
    reads.add(command);
    runs.add([command, ...args]);
    return _answer(outputs[command] ?? const ReadFailure.unavailable());
  }

  @override
  Future<String> readFile(String path) {
    reads.add('file $path');
    return _answer(files[path] ?? const ReadFailure.unavailable());
  }

  @override
  Future<num>? mtimeMs(String path) => mtimes[path] == null ? null : Future.value(mtimes[path]);
}

/// A platform bridge whose native side is `answer` (it may throw, or return a
/// future that never completes), and whose support folder is `support` (none:
/// no channel).
final class FakeBridge extends PlatformBridge {
  FakeBridge({FutureOr<Object?> Function(String method, Map<String, Object?> arguments)? answer, this.support})
      : _answer = answer ?? ((_, __) => throw const NoPlatformChannel());

  final FutureOr<Object?> Function(String method, Map<String, Object?> arguments) _answer;
  String? support;
  final List<(String, Map<String, Object?>)> calls = [];

  /// Each call as `[method, arguments]`, for a deep comparison.
  List<List<Object?>> get called => [for (final (method, arguments) in calls) [method, arguments]];

  @override
  Future<Object?> invoke(String method, [Map<String, Object?> arguments = const {}]) async {
    calls.add((method, arguments));
    return _answer(method, arguments);
  }

  @override
  Future<String> supportDirectory() async => support ?? (throw const NoPlatformChannel());
}

/// A bridge that answers every method with `value`.
FakeBridge answering(Object? value, {String? support}) => FakeBridge(answer: (_, __) => value, support: support);

/// A fingerprint as the SDK hashes one.
String fp(String raw) => hashFingerprint(raw);
