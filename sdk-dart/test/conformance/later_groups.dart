// The groups after the first ones: the later groups, the key sets, the
// licence files, the user lock and the key pickup, answered as
// the reference's replay-*.ts answer them.

import 'dart:convert';

import 'package:keygrant/src/core/entitlements.dart';
import 'package:keygrant/src/core/jws.dart';
import 'package:keygrant/src/core/keys.dart';
import 'package:keygrant/src/core/lease.dart';
import 'package:keygrant/src/core/license_file.dart';
import 'package:keygrant/src/core/link.dart';
import 'package:keygrant/src/core/offline.dart';
import 'package:keygrant/src/core/pickup.dart';
import 'package:keygrant/src/core/wire.dart';

import 'harness.dart';
import 'inputs.dart';

void laterGroups() {
  conformanceGroup('majors', (v) => {'expect': majorOf(intOr(v['configured']))});
  conformanceGroup('referencedLinks',
      (v) => {'expect': referencedLink(v['link'] as String, v['reference'] as String)});
  conformanceGroup('trialReportDue', (v) => {'expect': trialReportDue(stateOf(v['state']), intOr(v['now'])!)});
}

void keyGroups() {
  conformanceGroup('keyIds', (v) {
    try {
      return {'expect': keyId(v['jwk'])};
    } on LicenseConfigError {
      return {'expect': null};
    }
  });
  conformanceGroup('keySets', (v) async {
    final set = importVerifyingKeys(v['keys'] as List<Object?>);
    final verified = await verifyLease(v['token'] as String, set, intOr(v['now'])!);
    return {'kids': [for (final k in set) k.kid], 'verify': verified.toJson()};
  });
  conformanceGroup('grants', (v) => {'expect': grants(entitlementsOf(v['ent']), v['code'] as String)});
}

void fileGroups() {
  conformanceGroup('licenseFileContainers', (v) => {'expect': licenseFileToken(b64urlDecode(v['bytes'] as String))});
  conformanceGroup('licenseFiles', (v) async {
    final verified = await verifyLicenseFile(v['token'] as String, importVerifyingKeys(v['keys'] as List<Object?>));
    final check = checkLicenseFile(verified, v['product'] as String, intOr(v['major'])!, texts(v['revoked']));
    return {'verify': verified.toJson(), 'expect': check.toJson(), 'status': licenseFileStatus(check).toJson()};
  }, outputs: {'verify', 'expect', 'status'});
  conformanceGroup('filesAsLeases', (v) async {
    final holder = holderOf(v['holder']);
    final verified = await verifyLease(v['token'] as String, fileKeys(), intOr(v['now'])!);
    final check = checkLease(verified, v['product'] as String, intOr(v['major'])!, holder);
    return {
      'verify': verified.toJson(),
      'expect': check.toJson(),
      'trial': trialLeaseValid(verified, v['product'] as String, holder.claims, holder.canTell),
    };
  });
}

void userLockGroups() {
  conformanceGroup('typedFor', (v) {
    final typed = typedFor(email: v['email'] as String?, code: v['code'] as String?);
    return {
      'expect': typed.refused != null ? {'refused': typed.refused!.wire} : {'send': typed.send},
    };
  });
  conformanceGroup('userLockErrors', (v) => {'expect': mapServerError(v['error']).wire});
}

void pickupGroups() {
  conformanceGroup('pickupAsks', (v) => {'expect': pickupAsk(v['email'] as String, v['code'] as String?).toJson()});
  conformanceGroup('pickupRefusals', (v) => {'expect': pickupRefusal(v['json']).toJson()});
  conformanceGroup('pickedKeys', (v) => {'expect': pickedKeysOf(v['json'])?.map((k) => k.toJson()).toList()});
  conformanceGroup('pickupChoices', (v) {
    final keys = [for (final k in v['keys'] as List) PickedKey.fromJson(k)!];
    return {'expect': chosenKey(keys, intOr(v['major'])!, intOr(v['now'])!).toJson()};
  });
}

/// A vector's value as JSON text, for a message.
String shown(Object? value) => jsonEncode(value);
