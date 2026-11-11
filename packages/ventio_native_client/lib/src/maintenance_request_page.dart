import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'command_id.dart';
import 'local_command_queue.dart';
import 'transport_fixture.dart';

class MaintenanceRequestPage extends StatefulWidget {
  const MaintenanceRequestPage({
    required this.queue,
    required this.transport,
    super.key,
  });

  final LocalCommandQueue queue;
  final CommandTransport transport;

  @override
  State<MaintenanceRequestPage> createState() => _MaintenanceRequestPageState();
}

class _MaintenanceRequestPageState extends State<MaintenanceRequestPage> {
  final _customerName = TextEditingController();
  final _deviceModel = TextEditingController();
  final _problemDescription = TextEditingController();
  List<QueueEntry> _entries = const [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _customerName.dispose();
    _deviceModel.dispose();
    _problemDescription.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final entries = await widget.queue.list();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _saveRequest() async {
    final customerName = _customerName.text.trim();
    final deviceModel = _deviceModel.text.trim();
    final problemDescription = _problemDescription.text.trim();
    if (customerName.isEmpty ||
        deviceModel.isEmpty ||
        problemDescription.isEmpty) {
      _showMessage('Complete all fields before saving.');
      return;
    }

    setState(() => _saving = true);
    try {
      final commandId = createCommandId();
      final now = DateTime.now().toUtc().toIso8601String();
      final envelope = CommandEnvelope.fromJson({
        'protocolVersion': 0,
        'commandId': commandId,
        'type': 'maintenance.create',
        'typeVersion': 1,
        'tenantId': 'local-demo-tenant',
        'companyId': 'local-demo-company',
        'branchId': 'local-demo-branch',
        'aggregateId': 'maintenance-$commandId',
        'expectedRevision': null,
        'dependsOn': <String>[],
        'payload': {
          'customerName': customerName,
          'deviceModel': deviceModel,
          'problemDescription': problemDescription,
          'status': 'new',
        },
        'clientContext': {
          'deviceId': 'local-demo-device',
          'actorId': 'local-demo-user',
          'moduleVersion': '0.1.0',
          'docTypeVersion': 1,
          'clientTimestamp': now,
        },
      });
      await widget.queue.enqueue(envelope);
      _customerName.clear();
      _deviceModel.clear();
      _problemDescription.clear();
      await _refresh();
      _showMessage('Saved locally. Host has not accepted this request.');
    } catch (error) {
      _showMessage('Could not save the local request: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _runFixture(QueueEntry entry) async {
    try {
      await widget.queue.recordAttempt(entry.envelope.commandId);
      final receipt = await widget.transport.send(entry.envelope);
      if (receipt.source != TransportSource.fixture) {
        throw const FormatException(
          'This screen only accepts fixture responses.',
        );
      }
      await widget.queue.recordFixtureReceipt(
        entry.envelope.commandId,
        receipt,
      );
      await _refresh();
      _showMessage('Fixture response saved. Host status remains Pending.');
    } catch (error) {
      _showMessage('Fixture could not run: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const VentioText('native.ui.ventio_framework'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: VentioText('native.ui.offline_first_proof')),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                VentioText(
                  'native.ui.maintenance_requests',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const VentioText(
                  'native.ui.create_requests_offline_a_local_save_is_provisional_and_is_not_host_appr',
                ),
                const SizedBox(height: 16),
                _NoticeCard(
                  icon: Icons.cloud_off_outlined,
                  title: context.ventioText(
                    'native.ui.local_only_demonstration',
                  ),
                  body: context.ventioText(
                    'native.ui.no_host_connection_is_configured_the_fixture_below_is_simulated_and_cann',
                  ),
                ),
                const SizedBox(height: 20),
                _requestForm(context),
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: VentioText(
                        'native.ui.local_command_queue',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Text(
                      context.ventioText(
                        'native.ui.saved_count',
                        params: {'count': _entries.length},
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_entries.isEmpty)
                  _NoticeCard(
                    icon: Icons.inbox_outlined,
                    title: context.ventioText('native.ui.no_requests_yet'),
                    body: context.ventioText(
                      'native.ui.saved_requests_will_remain_in_this_device_s_local_queue_after_the_app_re',
                    ),
                  )
                else
                  for (final entry in _entries) _entryCard(context, entry),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _requestForm(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VentioText(
              'native.ui.new_request',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _customerName,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.customer_name'),
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceModel,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.device_model'),
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _problemDescription,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.problem_description'),
                border: OutlineInputBorder(),
              ),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saving ? null : _saveRequest,
                icon: const Icon(Icons.save_outlined),
                label: _saving
                    ? const VentioText('native.ui.saving')
                    : const VentioText('native.ui.save_locally'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryCard(BuildContext context, QueueEntry entry) {
    final payload = entry.envelope.payload;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  avatar: Icon(
                    entry.isHostConfirmed ? Icons.verified : Icons.schedule,
                    size: 18,
                  ),
                  label: Text(entry.hostStatus.label),
                ),
                Text(
                  context.ventioText(
                    'native.ui.command_id',
                    params: {'commandId': entry.envelope.commandId},
                  ),
                ),
              ],
            ),
            Text('${payload['customerName']} · ${payload['deviceModel']}'),
            const SizedBox(height: 4),
            Text('${payload['problemDescription']}'),
            const SizedBox(height: 8),
            Text(
              context.ventioText(
                'native.ui.saved_attempts',
                params: {'count': entry.attemptCount},
              ),
            ),
            if (entry.fixtureReceipt != null) ...[
              const SizedBox(height: 10),
              Text(
                context.ventioText(
                  'native.ui.fixture_status',
                  params: {'status': entry.fixtureReceipt!.status},
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (entry.isPending) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () => _runFixture(entry),
                  icon: const Icon(Icons.science_outlined),
                  label: const VentioText('native.ui.run_local_fixture'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
