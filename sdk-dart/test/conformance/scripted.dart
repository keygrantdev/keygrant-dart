// A machine-id source scripted by a vector (`machineIds.source`): the reads
// the reference makes, answered from the JSON (the reference's scripted.ts).

import 'package:keygrant/src/core/machine_id.dart';

const String _standardReg = r'C:\Windows\System32\reg.exe';

/// What a scripted error means: killed or ended by a signal is this time
/// only; an exit code is for good; an errno is for good when it says there is
/// nothing to read, else this time only.
ReadFailure failureOf(Object? error) {
  final e = (error as Map<String, Object?>?) ?? const {};
  if (e['killed'] == true || e['signal'] is String) return const ReadFailure.transient();
  final code = e['code'];
  if (code is num) return const ReadFailure.unavailable();
  const forGood = {'ENOENT', 'EACCES', 'EPERM', 'ENOTDIR', 'EISDIR'};
  return code is String && forGood.contains(code) ? const ReadFailure.unavailable() : const ReadFailure.transient();
}

final class Scripted extends MachineIdSource {
  Scripted(Map<String, Object?> source)
      : platform = source['platform'] as String,
        _systemRoot = source['systemRoot'] as String?,
        _files = (source['files'] as Map<String, Object?>?) ?? const {},
        _commands = (source['commands'] as Map<String, Object?>?) ?? const {};

  @override
  final String platform;
  final String? _systemRoot;
  final Map<String, Object?> _files;
  final Map<String, Object?> _commands;

  Future<String> _command(String command) async {
    final answer = _commands[command] as Map<String, Object?>?;
    if (answer == null) throw const ReadFailure.unavailable();
    if (answer.containsKey('error')) throw failureOf(answer['error']);
    return (answer['output'] as String?) ?? '';
  }

  /// This SDK reads `MachineGuid` through the registry API, not `reg.exe`. The
  /// vectors script `reg.exe`, so this maps the script onto what the registry
  /// would hold: the value printed on the `MachineGuid REG_SZ` line (the
  /// standard reg.exe's, else `%SystemRoot%`'s when the standard one is not
  /// there), none when no such line, the failure otherwise. The SDK's own
  /// step, the id from the value, is what this pins.
  @override
  Future<String> windowsMachineGuid(Duration timeout) async {
    final standard = _commands[_standardReg] as Map<String, Object?>?;
    final notThere = standard == null || (standard['error'] as Map<String, Object?>?)?['code'] == 'ENOENT';
    final elsewhere = _systemRoot == null ? null : '$_systemRoot\\System32\\reg.exe';
    final output = notThere && elsewhere != null && elsewhere != _standardReg
        ? await _command(elsewhere)
        : await _command(_standardReg);
    final value = RegExp(r'MachineGuid\s+REG_SZ\s+(\S+)').firstMatch(output)?.group(1);
    if (value == null) throw const ReadFailure.unavailable();
    return value;
  }

  /// The vectors script `ioreg`: no IOKit read here.
  @override
  Future<String?> platformUuid(Duration timeout) async => null;

  @override
  Future<String> run(String command, List<String> args, Duration timeout) => _command(command);

  @override
  Future<String> readFile(String path) async {
    final file = _files[path] as Map<String, Object?>?;
    if (file == null) throw const ReadFailure.unavailable();
    if (file.containsKey('error')) throw failureOf(file['error']);
    return (file['content'] as String?) ?? '';
  }

  @override
  Future<num>? mtimeMs(String path) async {
    final mtime = (_files[path] as Map<String, Object?>?)?['mtimeMs'];
    if (mtime is! num) throw const ReadFailure.unavailable();
    return mtime;
  }
}
