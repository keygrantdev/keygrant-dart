/// The SDK's own time bounds (the SDK contract, section 7), set apart so a
/// test can run them shorter.
library;

/// How long past its HTTP bound a call may hold the next one waiting (ms).
const int lockGraceMs = 15000;

/// The bounds a licence keeps.
final class Timing {
  const Timing({
    this.lockGrace = const Duration(milliseconds: lockGraceMs),
    this.statusCheck = const Duration(seconds: 5),
    this.machineId = const Duration(seconds: 2),
    this.activateMachineId = const Duration(seconds: 10),
    this.identifySlack = const Duration(seconds: 1),
  });

  /// How long past its HTTP bound a call may hold the next one waiting.
  final Duration lockGrace;

  /// How long a check `status()` makes on a valid lease may hold it up; also
  /// the bound of a trial's heal and of the launch report, and of a `use`
  /// request, which alone is cut to the HTTP bound when that is shorter.
  final Duration statusCheck;

  /// How long a status may spend reading the machine id.
  final Duration machineId;

  /// How long an activation or a trial start may.
  final Duration activateMachineId;

  /// How much longer than its own bound a fingerprinter's `identify` is given.
  final Duration identifySlack;

  static const standard = Timing();
}
