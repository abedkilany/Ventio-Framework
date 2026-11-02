import 'dart:convert';
import 'dart:io';

class HostLanEndpointInfo {
  const HostLanEndpointInfo({
    required this.endpoint,
    required this.alternativeEndpoints,
    required this.certificateSha256,
    required this.certificatePath,
  });

  final String endpoint;
  final List<String> alternativeEndpoints;
  final String certificateSha256;
  final String certificatePath;

  static Future<HostLanEndpointInfo?> loadForWindows() async {
    if (!Platform.isWindows) return null;
    final programData = Platform.environment['ProgramData'];
    if (programData == null || programData.trim().isEmpty) return null;
    final root = Directory('$programData\\Ventio\\Host');
    final infoFile = File('${root.path}\\host-lan-info.json');
    final certificateFile = File('${root.path}\\host-lan-certificate.pem');
    if (FileSystemEntity.isLinkSync(root.path) ||
        FileSystemEntity.isLinkSync(infoFile.path) ||
        FileSystemEntity.isLinkSync(certificateFile.path)) {
      return null;
    }
    try {
      if (!await infoFile.exists() || !await certificateFile.exists()) {
        return null;
      }
      final raw = await infoFile.readAsString();
      if (raw.length > 16 * 1024) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> || decoded['formatVersion'] != 1) {
        return null;
      }
      final endpoint = decoded['endpoint'];
      final fingerprint = decoded['certificateSha256'];
      final certificatePath = decoded['certificatePath'];
      final listenerEnabled = decoded['listenerEnabled'];
      final alternatives = decoded['alternativeEndpoints'];
      if (endpoint is! String ||
          fingerprint is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
          certificatePath is! String ||
          listenerEnabled != true ||
          alternatives is! List<Object?> ||
          alternatives.length > 32) {
        return null;
      }
      final uri = Uri.tryParse(endpoint);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.port != 8443 ||
          uri.userInfo.isNotEmpty ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.query.isNotEmpty ||
          uri.fragment.isNotEmpty ||
          !RegExp(r'^[A-Za-z0-9.-]{1,253}$').hasMatch(uri.host)) {
        return null;
      }
      final expectedCertificatePath = '${root.path}\\host-lan-certificate.pem';
      if (certificatePath.toLowerCase() !=
          expectedCertificatePath.toLowerCase()) {
        return null;
      }
      final parsedAlternatives = <String>[];
      for (final value in alternatives) {
        if (value is! String) return null;
        final alternative = Uri.tryParse(value);
        if (alternative == null ||
            alternative.scheme != 'https' ||
            alternative.port != 8443 ||
            alternative.userInfo.isNotEmpty ||
            alternative.path.isNotEmpty ||
            alternative.query.isNotEmpty ||
            alternative.fragment.isNotEmpty ||
            !RegExp(r'^[0-9.]+$').hasMatch(alternative.host)) {
          return null;
        }
        parsedAlternatives.add(value);
      }
      return HostLanEndpointInfo(
        endpoint: endpoint,
        alternativeEndpoints: List.unmodifiable(parsedAlternatives),
        certificateSha256: fingerprint,
        certificatePath: certificatePath,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
