import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'host_extension_packages.dart';

class HostExtensionReviewPage extends StatefulWidget {
  const HostExtensionReviewPage({
    required this.client,
    required this.companyId,
    required this.branchId,
    required this.actorId,
    super.key,
  });

  final HostExtensionPackageClient client;
  final String companyId;
  final String branchId;
  final String actorId;

  @override
  State<HostExtensionReviewPage> createState() =>
      _HostExtensionReviewPageState();
}

class _HostExtensionReviewPageState extends State<HostExtensionReviewPage> {
  List<HostExtensionSubmission> _submissions = const [];
  String? _error;
  bool _loading = false;
  String? _busyHash;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.client.listSubmissions(
        companyId: widget.companyId,
        branchId: widget.branchId,
      );
      if (!mounted) return;
      setState(() => _submissions = entries);
    } on HostPackageTransportException catch (error) {
      if (mounted) setState(() => _error = error.code);
    } on Object {
      if (mounted) setState(() => _error = 'HOST_REVIEW_UNAVAILABLE');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _review(
    HostExtensionSubmission submission,
    String decision,
  ) async {
    String? reason;
    if (decision == 'REJECT') {
      reason = await _rejectionReason();
      if (reason == null || reason.trim().isEmpty) return;
    } else {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const VentioText(
            'native.ui.approve_extension_candidate_title',
          ),
          content: Text(
            context.ventioText(
              'native.ui.approve_extension_candidate_confirmation',
              params: {
                'moduleId': submission.bundle.moduleId,
                'version': submission.bundle.version,
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VentioText('native.ui.cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const VentioText('native.ui.approve'),
            ),
          ],
        ),
      );
      if (approved != true) return;
    }
    setState(() {
      _busyHash = submission.packageSha256;
      _error = null;
    });
    try {
      final result = await widget.client.reviewSubmission(
        submission: submission,
        companyId: widget.companyId,
        branchId: widget.branchId,
        decision: decision,
        reason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.ventioText(
              'native.ui.extension_candidate_result',
              params: {'result': result},
            ),
          ),
        ),
      );
      await _load();
    } on HostPackageTransportException catch (error) {
      if (mounted) setState(() => _error = error.code);
    } on Object {
      if (mounted) setState(() => _error = 'HOST_REVIEW_UNAVAILABLE');
    } finally {
      if (mounted) setState(() => _busyHash = null);
    }
  }

  Future<String?> _rejectionReason() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const VentioText('native.ui.reject_extension_candidate_title'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.reason'),
              helperText: context.ventioText(
                'native.ui.extension_rejection_reason_help',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VentioText('native.ui.cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const VentioText('native.ui.reject'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VentioText('native.ui.extension_candidate_review'),
      actions: [
        IconButton(
          tooltip: context.ventioText('native.ui.refresh_candidates'),
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: _loading && _submissions.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: VentioText(
                        'native.ui.extension_review_explanation',
                      ),
                    ),
                  ),
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          context.ventioText(
                            'native.ui.extension_review_failed',
                            params: {'reference': _error},
                          ),
                        ),
                      ),
                    ),
                  if (!_loading && _submissions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(
                        child: VentioText('native.ui.no_pending_candidates'),
                      ),
                    ),
                  for (final item in _submissions) _candidateCard(item),
                ],
              ),
      ),
    ),
  );

  Widget _candidateCard(HostExtensionSubmission submission) {
    final bundle = submission.bundle;
    final isSelf = submission.submittedBy == widget.actorId;
    final busy = _busyHash == submission.packageSha256;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${bundle.moduleId} / ${bundle.version}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              context.ventioText(
                'native.ui.submitted_by',
                params: {'actorId': submission.submittedBy},
              ),
            ),
            Text(
              context.ventioText(
                'native.ui.submitted_at',
                params: {'timestamp': submission.submittedAtUtc.toLocal()},
              ),
            ),
            const SizedBox(height: 8),
            const VentioText('native.ui.package_sha256'),
            SelectableText(submission.packageSha256),
            const SizedBox(height: 10),
            Text(
              context.ventioText(
                'native.ui.extension_name',
                params: {'name': bundle.manifest.displayName},
              ),
            ),
            Text(
              context.ventioText(
                'native.ui.document_types',
                params: {'types': bundle.manifest.docTypes.join(', ')},
              ),
            ),
            Text(
              context.ventioText(
                'native.ui.minimum_platform_api',
                params: {'version': bundle.manifest.minPlatformApi},
              ),
            ),
            if (isSelf)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: VentioText('native.ui.extension_self_review_blocked'),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: isSelf || busy || _busyHash != null
                      ? null
                      : () => _review(submission, 'APPROVE'),
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined),
                  label: const VentioText('native.ui.approve'),
                ),
                OutlinedButton.icon(
                  onPressed: isSelf || busy || _busyHash != null
                      ? null
                      : () => _review(submission, 'REJECT'),
                  icon: const Icon(Icons.block_outlined),
                  label: const VentioText('native.ui.reject'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
