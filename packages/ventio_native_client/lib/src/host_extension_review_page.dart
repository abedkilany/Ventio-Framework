import 'package:flutter/material.dart';
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
          title: const Text('Approve extension candidate?'),
          content: Text(
            '${submission.bundle.moduleId} ${submission.bundle.version} will become an approved Host release for this scope.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Approve'),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Candidate $result.')));
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
          title: const Text('Reject extension candidate'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Reason',
              helperText: 'The reason is stored in the Host audit record.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Reject'),
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
      title: const Text('Extension candidate review'),
      actions: [
        IconButton(
          tooltip: 'Refresh candidates',
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
                      child: Text(
                        'Review declarative extension metadata and its digest before deciding. Ventio does not execute arbitrary package code. Decisions are recorded by the Host and become available to Clients only after approval.',
                      ),
                    ),
                  ),
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Review could not be completed. Reference: $_error',
                        ),
                      ),
                    ),
                  if (!_loading && _submissions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(child: Text('No pending candidates.')),
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
            Text('Submitted by ${submission.submittedBy}'),
            Text('Submitted ${submission.submittedAtUtc.toLocal()}'),
            const SizedBox(height: 8),
            const Text('Package SHA-256'),
            SelectableText(submission.packageSha256),
            const SizedBox(height: 10),
            Text('Name: ${bundle.manifest.displayName}'),
            Text('Document types: ${bundle.manifest.docTypes.join(', ')}'),
            Text('Minimum platform API: ${bundle.manifest.minPlatformApi}'),
            if (isSelf)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'You submitted this candidate. A different authorized administrator must review it.',
                ),
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
                  label: const Text('Approve'),
                ),
                OutlinedButton.icon(
                  onPressed: isSelf || busy || _busyHash != null
                      ? null
                      : () => _review(submission, 'REJECT'),
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('Reject'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
