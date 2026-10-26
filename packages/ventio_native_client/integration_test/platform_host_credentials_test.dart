import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/platform_host_credentials.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('platform secure storage persists and removes Host credentials', (
    tester,
  ) async {
    const token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
    final endpoint = Uri.parse(
      'https://credential-${DateTime.now().microsecondsSinceEpoch}.invalid',
    );
    final vault = HostCredentialVault(PlatformHostCredentialBackend());

    try {
      await vault.save(endpoint, token);

      final reopenedVault = HostCredentialVault(
        PlatformHostCredentialBackend(),
      );
      expect(await reopenedVault.read(endpoint), token);

      await reopenedVault.delete(endpoint);
      expect(await vault.read(endpoint), isNull);
    } finally {
      await vault.delete(endpoint);
    }
  });
}
