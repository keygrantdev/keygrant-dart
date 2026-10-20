part of 'license.dart';

/// The licence-file machinery (files.ts): taking a file an app was handed,
/// the status a stored offline file gives, and removing it. Never online: a
/// key file's key is activated as a typed key is.
abstract class _FileEngine extends _TrialEngine {
  _FileEngine(super.config, super.timing) : _revokedFiles = List.unmodifiable(config.revokedLicenseFiles);

  final List<String> _revokedFiles;

  Future<LicenseFileCheck> _checkFile(String token) async =>
      checkLicenseFile(await verifyLicenseFile(token, _keys), _product, _major, _revokedFiles);

  /// The status the stored offline licence file gives, verified again now, or
  /// null when none is stored.
  Future<LicenseStatus?> _fileStatus(StoredState state) async {
    final stored = state.licenseFile;
    return stored == null ? null : licenseFileStatus(await _checkFile(stored));
  }

  /// Take a licence file: an offline file stored, replacing any stored before;
  /// a key file's key handed to `activate`. Nothing is stored for a file refused.
  Future<ImportLicenseFileResult> _importFile(Object content, Future<ActivateResult> Function(String key) activate) async {
    final token = licenseFileToken(content);
    if (token == null) return const LicenseFileRefused(LicenseFileError.malformed);
    final check = await _checkFile(token);
    final claims = check.claims;
    if (!check.ok || claims == null) return LicenseFileRefused(check.reason!);
    if (claims.kind == LicenseFileKind.key) {
      final activated = await activate(claims.sub);
      return switch (activated) {
        Activated() => LicenseFileImported(LicenseFileKind.key, claims.licensedTo),
        ActivateFailed(:final error) => LicenseFileActivationFailed(error),
      };
    }
    // Unbased: it is about no activation, so it lands as it is on whatever is stored.
    await _save({Field.licenseFile: token});
    return LicenseFileImported(LicenseFileKind.offline, claims.licensedTo);
  }

  /// Drop the stored offline licence file, if any. Throws when that cannot be saved.
  Future<void> _removeFile() => _save(const {Field.licenseFile: null});
}
