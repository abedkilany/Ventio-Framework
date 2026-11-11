import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_extension_review_page.dart';
import 'package:ventio_native_client/src/host_credentials.dart';

class _MemoryCredentialBackend implements HostCredentialBackend {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _ReviewClient extends HostExtensionPackageClient {
  _ReviewClient(this.submission)
    : super(
        endpoint: Uri.parse('https://host.example'),
        credentials: HostCredentialVault(_MemoryCredentialBackend()),
      );

  final HostExtensionSubmission submission;
  String? decision;

  @override
  Future<List<HostExtensionSubmission>> listSubmissions({
    required String companyId,
    required String branchId,
    int limit = 3,
  }) async => [submission];

  @override
  Future<String> reviewSubmission({
    required HostExtensionSubmission submission,
    required String companyId,
    required String branchId,
    required String decision,
    String? reason,
  }) async {
    this.decision = decision;
    return decision == 'APPROVE' ? 'APPROVED' : 'REJECTED';
  }
}

ExtensionBundle _bundle() => ExtensionBundle.fromJson({
  'manifest': {
    'manifestVersion': 0,
    'moduleId': 'sync.test',
    'version': '0.1.0',
    'minPlatformApi': '0.1.0',
    'displayName': 'Sync Test',
    'displayNameKey': 'extension.sync_test.name',
    'englishCatalog': 'localization/en.sync_test.json',
    'dependencies': <String>[],
    'docTypes': ['Product'],
    'commands': <Object>[],
    'requiredCapabilities': <String>[],
    'offline': {'enabled': false, 'allowedCommands': <String>[]},
  },
  'docTypes': [
    {
      'name': 'Product',
      'moduleId': 'sync.test',
      'schemaVersion': 1,
      'kind': 'operational',
      'label': 'Product',
      'labelKey': 'extension.sync_test.product',
      'operations': ['read'],
      'permissions': {'read': 'extension.sync_test.product.read'},
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'label': 'Name',
          'labelKey': 'extension.sync_test.product.name',
          'maxLength': 100,
        },
      ],
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
    },
  ],
  'dependencyVersions': <String, String>{},
  'englishCatalog': {
    'extension.sync_test.name': 'Sync Test',
    'extension.sync_test.product': 'Product',
    'extension.sync_test.product.name': 'Name',
  },
});

HostExtensionSubmission _submission(String submitter) =>
    HostExtensionSubmission(
      bundle: _bundle(),
      packageSha256: 'a' * 64,
      submittedBy: submitter,
      submittedAtUtc: DateTime.utc(2026, 11, 8),
    );

void main() {
  testWidgets('Authorized Host operator reviews and approves a candidate', (
    tester,
  ) async {
    final client = _ReviewClient(_submission('publisher'));
    await tester.pumpWidget(
      MaterialApp(
        home: HostExtensionReviewPage(
          client: client,
          companyId: 'CD',
          branchId: 'EF',
          actorId: 'reviewer',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('sync.test / 0.1.0'), findsOneWidget);
    expect(find.text('Package SHA-256'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Approve extension candidate?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await tester.pumpAndSettle();
    expect(client.decision, 'APPROVE');
    expect(find.text('Candidate APPROVED.'), findsOneWidget);
  });

  testWidgets('Candidate submitter cannot approve from the review UI', (
    tester,
  ) async {
    final client = _ReviewClient(_submission('publisher'));
    await tester.pumpWidget(
      MaterialApp(
        home: HostExtensionReviewPage(
          client: client,
          companyId: 'CD',
          branchId: 'EF',
          actorId: 'publisher',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final approve = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Approve'),
    );
    final reject = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Reject'),
    );
    expect(approve.onPressed, isNull);
    expect(reject.onPressed, isNull);
    expect(
      find.text(
        'You submitted this candidate. A different authorized administrator must review it.',
      ),
      findsOneWidget,
    );
    expect(client.decision, isNull);
  });
}
