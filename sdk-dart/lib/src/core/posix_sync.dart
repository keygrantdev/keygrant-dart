/// Flushing a folder's entries to the disk on POSIX (after a rename in it),
/// which dart:io cannot do: `open(dir, O_RDONLY)`, `fsync`, `close` through
/// the C library. Best-effort: a system where it cannot be done is left as it is.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _OpenC = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef _OpenDart = int Function(Pointer<Utf8> path, int flags);
typedef _FdC = Int32 Function(Int32 fd);
typedef _FdDart = int Function(int fd);

/// Flush `dir`'s entries to the disk. Never throws. Windows opens no handle on
/// a folder to flush; NTFS journals the rename itself.
void syncDirectory(String dir) {
  if (Platform.isWindows) return;
  try {
    final libc = DynamicLibrary.process();
    final open = libc.lookupFunction<_OpenC, _OpenDart>('open');
    final fsync = libc.lookupFunction<_FdC, _FdDart>('fsync');
    final close = libc.lookupFunction<_FdC, _FdDart>('close');
    final path = dir.toNativeUtf8();
    try {
      final fd = open(path, 0);
      if (fd < 0) return;
      fsync(fd);
      close(fd);
    } finally {
      malloc.free(path);
    }
  } catch (_) {
    // Best-effort.
  }
}
