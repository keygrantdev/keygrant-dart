/// `MachineGuid` read through the Windows registry API, in the 64-bit view
/// whatever this process is (`RegGetValueW` with `RRF_SUBKEY_WOW6464KEY`, as
/// the C++ SDK reads it): no `reg.exe` process at every status, and nothing an
/// endpoint-security tool that blocks `reg.exe` can stall.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'machine_id.dart';

typedef _RegGetValueC = Int32 Function(
    IntPtr hkey, Pointer<Utf16> subKey, Pointer<Utf16> value, Uint32 flags, Pointer<Uint32> type, Pointer<Void> data,
    Pointer<Uint32> size);
typedef _RegGetValueDart = int Function(
    int hkey, Pointer<Utf16> subKey, Pointer<Utf16> value, int flags, Pointer<Uint32> type, Pointer<Void> data,
    Pointer<Uint32> size);

/// `HKEY_LOCAL_MACHINE`, sign-extended as Windows defines it.
const int _hkeyLocalMachine = -0x7FFFFFFE;
const int _rrfRtRegSz = 0x00000002;
const int _rrfSubkeyWow6464Key = 0x00010000;
const int _errorSuccess = 0;

/// Errors that mean there is no id to read, now or on the next try: the key or
/// value is not there, it is not ours to read, or it is not a text.
const Set<int> _forGood = {2, 3, 5, 1630};

/// The `MachineGuid` value. Throws a [ReadFailure].
String readWindowsMachineGuid() {
  final DynamicLibrary advapi;
  try {
    advapi = DynamicLibrary.open('advapi32.dll');
  } catch (_) {
    throw const ReadFailure.unavailable();
  }
  final regGetValue = advapi.lookupFunction<_RegGetValueC, _RegGetValueDart>('RegGetValueW');
  final subKey = r'SOFTWARE\Microsoft\Cryptography'.toNativeUtf16();
  final name = 'MachineGuid'.toNativeUtf16();
  final size = calloc<Uint32>();
  try {
    const flags = _rrfRtRegSz | _rrfSubkeyWow6464Key;
    var status = regGetValue(_hkeyLocalMachine, subKey, name, flags, nullptr, nullptr, size);
    if (status != _errorSuccess) throw _failure(status);
    final data = calloc<Uint8>(size.value + 2);
    try {
      status = regGetValue(_hkeyLocalMachine, subKey, name, flags, nullptr, data.cast(), size);
      if (status != _errorSuccess) throw _failure(status);
      return data.cast<Utf16>().toDartString();
    } finally {
      calloc.free(data);
    }
  } finally {
    calloc.free(subKey);
    calloc.free(name);
    calloc.free(size);
  }
}

ReadFailure _failure(int status) => _forGood.contains(status) ? const ReadFailure.unavailable() : const ReadFailure.transient();
