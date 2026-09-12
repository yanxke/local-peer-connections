import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

import 'device_test_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = DeviceTestController();
  runApp(DeviceTestApp(controller: controller));
  // CoreBluetooth can remain in .unknown if the first BLE operation is made
  // before Flutter has presented the application. Start after the first frame
  // so the fixture has the same active-app lifecycle as manual tests.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(controller.start());
    unawaited(controller.startControlServer());
  });
}

class DeviceTestApp extends StatelessWidget {
  const DeviceTestApp({required this.controller, super.key});

  final DeviceTestController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LPC Device Test',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      useMaterial3: true,
    ),
    home: DeviceTestHome(controller: controller),
  );
}

class DeviceTestHome extends StatelessWidget {
  const DeviceTestHome({required this.controller, super.key});

  final DeviceTestController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot();
      final connections = snapshot['connections'] as List<Object?>;
      final endpoints = snapshot['endpoints'] as List<Object?>;
      final knownPeerIds =
          (snapshot['knownPeerIds'] as List<Object?>? ?? const [])
              .whereType<String>()
              .toSet();
      final group = snapshot['group'];
      return Scaffold(
        appBar: AppBar(
          title: const Text('LPC Device Test'),
          actions: [
            IconButton(
              tooltip: 'Reset runtime',
              onPressed: controller.resetRuntime,
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _StatusCard(snapshot: snapshot),
            const SizedBox(height: 8),
            _ConnectionStateBanner(snapshot: snapshot),
            const SizedBox(height: 8),
            _TrafficPanel(
              controller: controller,
              snapshot: snapshot,
              group: false,
            ),
            const SizedBox(height: 8),
            _TrafficPanel(
              controller: controller,
              snapshot: snapshot,
              group: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: controller.start,
                    child: const Text('Start presence'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => controller.stopPresence(),
                    child: const Text('Stop presence'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _Section(
              title: 'Discovered endpoints (${endpoints.length})',
              child: endpoints.isEmpty
                  ? const Text('No LPC service endpoints observed.')
                  : Column(
                      children: [
                        for (final endpoint in endpoints)
                          _EndpointTile(
                            endpoint: endpoint as Map<String, Object?>,
                            onConnect: () =>
                                controller.connect(endpoint['id']! as String),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            _KnownPeersSection(controller: controller, snapshot: snapshot),
            const SizedBox(height: 8),
            _Section(
              title: 'Authenticated connections (${connections.length})',
              child: connections.isEmpty
                  ? const Text('No authenticated PeerConnections.')
                  : Column(
                      children: [
                        for (final connection
                            in connections.cast<Map<String, Object?>>())
                          ConnectionTile(
                            connection: connection,
                            isKnownPeer: knownPeerIds.contains(
                              connection['peerId'],
                            ),
                            onRemember: () => controller.rememberKnownPeer(
                              connection['peerId']! as String,
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            _Section(
              title: 'GroupSession',
              child: Text(
                group == null
                    ? 'No active group.'
                    : const JsonEncoder.withIndent('  ').convert(group),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            _Section(
              title: 'Recent diagnostics',
              child: SizedBox(
                height: 280,
                child: ListView.builder(
                  reverse: true,
                  itemCount: controller.events.length,
                  itemBuilder: (context, index) {
                    final event =
                        controller.events[controller.events.length - index - 1];
                    return Text(
                      jsonEncode(event),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.snapshot});

  final Map<String, Object?> snapshot;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        _statusText(),
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ),
  );

  String _statusText() {
    final telemetry =
        (snapshot['telemetry'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final percentages =
        (telemetry['connectionStatePercent'] as Map?)
            ?.cast<String, Object?>() ??
        const <String, Object?>{};
    String value(Object? input) =>
        input is num ? input.toStringAsFixed(2) : '$input';
    return 'Runtime: ${snapshot['runtimeState']}\n'
        'PeerId: ${snapshot['localPeerId']}\n'
        'Name: ${snapshot['displayName']}\n'
        'Control API: ${snapshot['controlApi']}\n'
        'Capabilities: ${snapshot['capabilities']}\n'
        'Messages sent/received: ${telemetry['messagesSent'] ?? 0} / '
        '${telemetry['messagesReceived'] ?? 0}\n'
        'Bytes sent/received: ${telemetry['bytesSent'] ?? 0} / '
        '${telemetry['bytesReceived'] ?? 0}\n'
        'Recent 5s send speed: '
        '${value(telemetry['messagesSentPerSecond'])} msg/s, '
        '${value(telemetry['bytesSentPerSecond'])} B/s\n'
        'Recent 5s receive speed: '
        '${value(telemetry['messagesReceivedPerSecond'])} msg/s, '
        '${value(telemetry['bytesReceivedPerSecond'])} B/s\n'
        'Connection time: connecting ${value(percentages['connecting'])}%, '
        'reconnecting ${value(percentages['reconnecting'])}%, '
        'connected ${value(percentages['connected'])}%';
  }
}

class _ConnectionStateBanner extends StatelessWidget {
  const _ConnectionStateBanner({required this.snapshot});

  final Map<String, Object?> snapshot;

  @override
  Widget build(BuildContext context) {
    final connections = snapshot['connections'] as List? ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: connections.isEmpty
            ? const Text('Connection state: no authenticated peers')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Connection state'),
                  const SizedBox(height: 4),
                  for (final value in connections)
                    if (value is Map)
                      Text(
                        '${value['peerId']}  •  ${value['state']}'
                        '${value['state'] == 'reconnecting' ? ' (retrying)' : ''}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: value['state'] == 'reconnecting'
                              ? Colors.orange.shade800
                              : null,
                        ),
                      ),
                ],
              ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

class _TrafficPanel extends StatefulWidget {
  const _TrafficPanel({
    required this.controller,
    required this.snapshot,
    required this.group,
  });

  final DeviceTestController controller;
  final Map<String, Object?> snapshot;
  final bool group;

  @override
  State<_TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<_TrafficPanel> {
  static const _messageSizes = <int>[
    8,
    16,
    32,
    64,
    128,
    256,
    512,
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
    65536,
  ];

  int _messageSizeIndex = 5;
  int _messagesPerSecond = 1;
  DeliveryMode _deliveryMode = DeliveryMode.reliableAcked;
  String? _peerId;

  int get _messageSize => _messageSizes[_messageSizeIndex];

  @override
  Widget build(BuildContext context) {
    final candidates = widget.group ? _groupPeers() : _directPeers();
    // Keep the control usable as soon as LPC reports a ready peer. A
    // destination can still be changed from the dropdown, but requiring a
    // first tap just to populate this field made Start appear inexplicably
    // disabled after authentication/reconnect.
    final selectedPeer = candidates.contains(_peerId)
        ? _peerId
        : candidates.isEmpty
        ? null
        : candidates.first;
    final selectedState = selectedPeer == null
        ? null
        : _peerState(selectedPeer);
    final selectedReady = selectedState == 'ready';
    final allTraffic = widget.snapshot['trafficTests'] as Map?;
    final traffic = (allTraffic?[widget.group ? 'group' : 'direct'] as Map?)
        ?.cast<String, Object?>();
    final running = traffic?['running'] == true;
    final title = widget.group ? 'Group message test' : 'Direct message test';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (candidates.isEmpty)
              const Text('Connect to a peer before starting a traffic test.')
            else
              DropdownButton<String>(
                isExpanded: true,
                value: selectedPeer,
                hint: const Text('Destination peer'),
                items: [
                  for (final peerId in candidates)
                    DropdownMenuItem(
                      value: peerId,
                      child: Text(
                        '$peerId (${_peerState(peerId) ?? 'unknown'})',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _peerId = value),
              ),
            Row(
              children: [
                const SizedBox(width: 92, child: Text('Message size')),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: (_messageSizes.length - 1).toDouble(),
                    divisions: _messageSizes.length - 1,
                    value: _messageSizeIndex.toDouble(),
                    label: '$_messageSize B',
                    onChanged: (value) =>
                        setState(() => _messageSizeIndex = value.round()),
                  ),
                ),
                SizedBox(width: 72, child: Text('$_messageSize B')),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 92, child: Text('Send rate')),
                Expanded(
                  child: Slider(
                    min: 1,
                    max: 20,
                    divisions: 19,
                    value: _messagesPerSecond.toDouble(),
                    label: '$_messagesPerSecond msg/s',
                    onChanged: (value) =>
                        setState(() => _messagesPerSecond = value.round()),
                  ),
                ),
                SizedBox(width: 72, child: Text('$_messagesPerSecond/s')),
              ],
            ),
            DropdownButton<DeliveryMode>(
              value: _deliveryMode,
              items: const [
                DropdownMenuItem(
                  value: DeliveryMode.reliableAcked,
                  child: Text('Reliable ACK'),
                ),
                DropdownMenuItem(
                  value: DeliveryMode.realtimeLatest,
                  child: Text('Non-reliable (realtime latest)'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _deliveryMode = value);
              },
            ),
            Row(
              children: [
                FilledButton(
                  onPressed: selectedPeer == null || !selectedReady || running
                      ? null
                      : () => _start(selectedPeer),
                  child: const Text('Start sending'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: running ? _stop : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
            if (selectedPeer != null && !selectedReady)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Peer is ${selectedState ?? 'unavailable'}; waiting for LPC to reconnect.',
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ),
            if (traffic != null && traffic['sent'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${running ? 'running' : 'stopped'}  sent ${traffic['sent']}  '
                  'ACKed ${traffic['acked']}  '
                  'pending ${traffic['pending']}  timed out ${traffic['timedOut']}  '
                  'loss ${(100 * ((traffic['lossRate'] as num?)?.toDouble() ?? 0)).toStringAsFixed(2)}%',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<String> _directPeers() => [
    for (final value in (widget.snapshot['connections'] as List? ?? const []))
      if (value is Map && value['peerId'] is String) value['peerId'] as String,
  ];

  String? _peerState(String peerId) {
    final connections = widget.snapshot['connections'] as List? ?? const [];
    for (final value in connections) {
      if (value is Map && value['peerId'] == peerId) {
        return value['state'] as String?;
      }
    }
    return null;
  }

  List<String> _groupPeers() {
    final group = widget.snapshot['group'];
    if (group is! Map) return const [];
    final localPeerId = widget.snapshot['localPeerId'];
    return [
      for (final value in (group['members'] as List? ?? const []))
        if (value is String && value != localPeerId) value,
    ];
  }

  Future<void> _start(String peerId) => widget.group
      ? widget.controller.startGroupSendTest(
          peerId: peerId,
          messageSize: _messageSize,
          messagesPerSecond: _messagesPerSecond.toDouble(),
          deliveryMode: _deliveryMode,
        )
      : widget.controller.startSendTest(
          peerId: peerId,
          messageSize: _messageSize,
          messagesPerSecond: _messagesPerSecond.toDouble(),
          deliveryMode: _deliveryMode,
        );

  Future<void> _stop() => widget.group
      ? widget.controller.stopGroupSendTest()
      : widget.controller.stopSendTest();
}

class _EndpointTile extends StatelessWidget {
  const _EndpointTile({required this.endpoint, required this.onConnect});

  final Map<String, Object?> endpoint;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text(endpoint['localName'] as String? ?? 'Unnamed LPC endpoint'),
    subtitle: Text(
      'id=${endpoint['id']} rssi=${endpoint['rssi']}',
      style: const TextStyle(fontFamily: 'monospace'),
    ),
    trailing: TextButton(onPressed: onConnect, child: const Text('Connect')),
  );
}

class _KnownPeersSection extends StatefulWidget {
  const _KnownPeersSection({required this.controller, required this.snapshot});

  final DeviceTestController controller;
  final Map<String, Object?> snapshot;

  @override
  State<_KnownPeersSection> createState() => _KnownPeersSectionState();
}

class _KnownPeersSectionState extends State<_KnownPeersSection> {
  final _peerIdController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _peerIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final values = (widget.snapshot['knownPeerIds'] as List? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    return _Section(
      title: 'Known friends (${values.length})',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Provision a 32-character PeerId from the other device using a trusted channel. LPC will probe and reconnect known peers automatically; BLE endpoint IDs are not stored.',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _peerIdController,
                  decoration: InputDecoration(
                    labelText: 'PeerId',
                    hintText: '32 hexadecimal characters',
                    errorText: _error,
                  ),
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _add, child: const Text('Add friend')),
            ],
          ),
          for (final peerId in values)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                peerId,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              trailing: IconButton(
                tooltip: 'Forget friend',
                icon: const Icon(Icons.person_remove),
                onPressed: () => widget.controller.forgetKnownPeer(peerId),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final value = _peerIdController.text.trim();
    try {
      await widget.controller.rememberKnownPeer(value);
      if (!mounted) return;
      _peerIdController.clear();
      setState(() => _error = null);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }
}

class ConnectionTile extends StatelessWidget {
  const ConnectionTile({
    required this.connection,
    required this.isKnownPeer,
    required this.onRemember,
    super.key,
  });

  final Map<String, Object?> connection;
  final bool isKnownPeer;
  final VoidCallback onRemember;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text(connection['peerId'] as String),
    subtitle: Text(
      'state=${connection['state']} security=${connection['security']}\n'
      'endpoint=${connection['endpointId']} transport=${connection['transport']} '
      'MTU=${connection['negotiatedMtu'] ?? 'unknown'}\n'
      'session=${connection['sessionId']}',
      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
    ),
    trailing: isKnownPeer
        ? null
        : TextButton(onPressed: onRemember, child: const Text('Remember')),
  );
}
