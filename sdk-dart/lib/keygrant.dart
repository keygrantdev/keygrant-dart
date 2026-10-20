/// KeyGrant licensing for Flutter apps: offline-verified leases, trials,
/// licence files, metered uses and key pickup, on iOS, Android, Windows,
/// macOS and Linux.
library;

export 'src/core/adapters.dart';
export 'src/core/device.dart' show DeviceIdentity, Fingerprinter;
export 'src/core/entitlements.dart'
    show Entitlement, FlagEntitlement, NumberEntitlement, TextEntitlement, MissingEntitlement, grants;
export 'src/core/fingerprinters.dart' show DesktopFingerprinter, MobileFingerprinter;
export 'src/core/http.dart' show HttpAdapter, HttpResponse, PackageHttp, defaultHttpTimeout;
export 'src/core/keys.dart' show LicenseConfigError, parseJwkSet;
export 'src/core/license/license.dart' show KeyGrantLicense;
export 'src/core/license_file.dart' show licenseFileExtension, licenseFileMediaType, maxLicenseFileBytes;
export 'src/core/meter_types.dart' show MeterStatus, SpendEntry, SpendKind, MeterFigure, BaseFigure;
export 'src/core/pickup.dart' show PickedKey, PickedVersions, PickedSale;
export 'src/core/results.dart';
export 'src/core/status.dart';
export 'src/core/storage.dart' show FileStorage;
export 'src/core/stored_state.dart' show StoredState, StatePatch;
export 'src/core/defaults.dart' show KeychainTrialStash;
export 'src/core/types.dart';
export 'src/platform/plugin.dart' show KeyGrantPlugin;
