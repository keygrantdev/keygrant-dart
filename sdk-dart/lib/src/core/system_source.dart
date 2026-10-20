/// The real system the machine id is read from on Windows, macOS and Linux
/// (machine-id.ts `systemMachineIdSource`), and this machine's host names as
/// Node names them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'identity.dart';
import 'machine_id.dart';
import 'platform_bridge.dart';
import 'windows_registry.dart';

/// This system's name as Node's `process.platform` gives it.
String nodePlatform() => switch (Platform.operatingSystem) {
      'windows' => 'win32',
      'macos' => 'darwin',
      final other => other,
    };

/// This process's architecture as Node's `process.arch` gives it.
/// The ABI reads `<os>_<arch>` (`windows_x64`, `macos_arm64`), and Dart's
/// architecture names (`x64`, `arm64`, `ia32`, `arm`, `riscv64`) are Node's.
String nodeArch() {
  final abi = Abi.current().toString();
  return abi.substring(abi.lastIndexOf('_') + 1);
}

/// This machine's host names, or null when they cannot be read.
HostNames? hostNames() {
  try {
    return HostNames(host: Platform.localHostname, platform: nodePlatform(), arch: nodeArch());
  } catch (_) {
    return null;
  }
}

/// POSIX errors that mean there is nothing to read, now or on the next try.
const Set<int> _forGood = {1, 2, 13, 20, 21};

ReadFailure _fileFailure(FileSystemException e) {
  final code = e.osError?.errorCode;
  return code != null && _forGood.contains(code) ? const ReadFailure.unavailable() : const ReadFailure.transient();
}

/// The real system: the registry API on Windows, IOKit through the plugin's
/// channel on macOS (else `ioreg`), the files on Linux.
final class SystemMachineIdSource extends MachineIdSource {
  SystemMachineIdSource({PlatformBridge? bridge}) : _bridge = bridge ?? PlatformBridge.instance;

  final PlatformBridge _bridge;

  @override
  String get platform => nodePlatform();

  @override
  Future<String> windowsMachineGuid(Duration timeout) async => readWindowsMachineGuid();

  @override
  Future<String?> platformUuid(Duration timeout) async {
    try {
      final uuid = await _bridge.invoke(NativeMethod.machineId);
      return uuid is String ? uuid : '';
    } on NoPlatformChannel {
      return null;
    } catch (_) {
      throw const ReadFailure.transient();
    }
  }

  @override
  Future<String> run(String command, List<String> args, Duration timeout) async {
    final Process process;
    try {
      process = await Process.start(command, args);
    } on ProcessException catch (e) {
      throw e.errorCode == 2 ? const ReadFailure.unavailable() : const ReadFailure.transient();
    }
    final out = process.stdout.transform(const SystemEncoding().decoder).join();
    unawaited(process.stderr.drain<void>());
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      throw const ReadFailure.transient();
    }
    if (code != 0) throw const ReadFailure.unavailable();
    return out;
  }

  @override
  Future<String> readFile(String path) async {
    try {
      // As Node's readFile(path, 'utf8'): an invalid sequence replaced, never a failure.
      return utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
    } on FileSystemException catch (e) {
      throw _fileFailure(e);
    }
  }

  @override
  Future<num>? mtimeMs(String path) async {
    final stat = await File(path).stat();
    if (stat.type == FileSystemEntityType.notFound) throw const ReadFailure.unavailable();
    return stat.modified.millisecondsSinceEpoch;
  }
}
