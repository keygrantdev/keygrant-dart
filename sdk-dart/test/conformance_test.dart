// Every group of `../conformance/vectors.json`, answered by the SDK's own
// decisions (test/conformance/), and the harness held to the file: the groups
// it answers are exactly the file's, and the constants are the reference's.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/src/core/clock.dart';
import 'package:keygrant/src/core/http.dart';
import 'package:keygrant/src/core/identity.dart';
import 'package:keygrant/src/core/lease.dart';
import 'package:keygrant/src/core/license_file.dart';
import 'package:keygrant/src/core/machine_id.dart';
import 'package:keygrant/src/core/meters.dart';
import 'package:keygrant/src/core/offline.dart';
import 'package:keygrant/src/core/wire.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/storage.dart';

import 'conformance/device_groups.dart';
import 'conformance/first_groups.dart';
import 'conformance/harness.dart';
import 'conformance/later_groups.dart';
import 'conformance/meter_groups.dart';

void main() {
  leaseGroups();
  patchGroups();
  wireGroups();
  deviceGroups();
  laterGroups();
  keyGroups();
  fileGroups();
  userLockGroups();
  meterGroups();
  pickupGroups();

  test('the harness answers every group in the file', () {
    final inFile = {
      for (final MapEntry(:key, :value) in vectors().entries)
        if (value is List) key,
    };
    expect({...answeredGroups, 'conventions'}, inFile);
  });

  test('every vector of every group was answered', () {
    // Runs after every group's test: each group's count is the file's, less its jsOnly vectors.
    for (final name in answeredGroups) {
      final all = groupOf(name);
      final typed = all.where((v) => v['jsOnly'] != true).length;
      expect(answeredVectors[name], typed, reason: name);
    }
    final total = answeredVectors.values.fold(0, (a, b) => a + b);
    // ignore: avoid_print
    print('conformance: ${answeredVectors.length} groups, $total vectors answered');
  });

  test('every number in the file is read as the nearest double', () {
    // The reference reads JSON numbers as doubles, correctly rounded; dart:convert must agree on
    // every number the file holds, the entitlements past 2^53 and in exponent form included.
    final tokens = numberTokens(File(vectorsPath).readAsStringSync());
    expect(tokens.length, greaterThan(1000));
    for (final token in tokens) {
      final read = (jsonDecode(token) as num).toDouble();
      expect(read, double.parse(token), reason: token);
    }
  });

  test('the constants are the reference\'s', () {
    final c = vectors()['constants'] as Map<String, Object?>;
    expect(c, {
      'OPEN_MAJOR': openMajor,
      'ASK_AGAIN_MS': askAgainMs,
      'RETRY_UNANSWERED_MS': retryUnansweredMs,
      'RENEW_WITHIN_MS': renewWithinMs,
      'CLOCK_TOLERANCE_MS': clockToleranceMs,
      'STATUS_CHECK_TIMEOUT_MS': statusCheckTimeoutMs,
      'DEFAULT_HTTP_TIMEOUT_MS': defaultHttpTimeout.inMilliseconds,
      'LOCK_GRACE_MS': lockGraceMs,
      'MACHINE_ID_TIMEOUT_MS': machineIdTimeout.inMilliseconds,
      'ACTIVATE_MACHINE_ID_TIMEOUT_MS': activateMachineIdTimeout.inMilliseconds,
      'BOOT_SLACK_MS': bootSlackMs,
      'MAX_DEVICE_NAME': maxDeviceName,
      'MAX_KEY': maxKey,
      'KEEP_CORRUPT': keepCorrupt,
      'STALE_TEMP_MS': staleTempMs,
      'UPDATE_ATTEMPTS': updateAttempts,
      'UNKNOWN_HOST': unknownHost,
      'TRIAL_REPORT_MS': trialReportMs,
      'MAX_LICENSE_FILE_BYTES': maxLicenseFileBytes,
      'MAX_METER_USES': maxMeterUses,
      'MAX_PENDING_SPENDS': maxPendingSpends,
      'MAX_PENDING_VOIDS': maxPendingVoids,
      'PENDING_MAX_MS': pendingMaxMs,
      'USE_TIMEOUT_MS': useTimeoutMs,
    });
  });
}

/// Every number in a JSON text, as written: each token outside a string that
/// starts with a digit or a minus.
List<String> numberTokens(String json) {
  final tokens = <String>[];
  var i = 0;
  while (i < json.length) {
    final c = json[i];
    if (c == '"') {
      i++;
      while (i < json.length && json[i] != '"') {
        i += json[i] == r'\' ? 2 : 1;
      }
      i++;
    } else if (c == '-' || (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39)) {
      final start = i;
      while (i < json.length && '0123456789+-.eE'.contains(json[i])) {
        i++;
      }
      tokens.add(json.substring(start, i));
    } else {
      i++;
    }
  }
  return tokens;
}
