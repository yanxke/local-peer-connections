import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

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
            _Section(
              title: 'Authenticated connections (${connections.length})',
              child: connections.isEmpty
                  ? const Text('No authenticated PeerConnections.')
                  : Column(
                      children: [
                        for (final connection in connections)
                          _ConnectionTile(
                            connection: connection as Map<String, Object?>,
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
        'Runtime: ${snapshot['runtimeState']}\n'
        'PeerId: ${snapshot['localPeerId']}\n'
        'Name: ${snapshot['displayName']}\n'
        'Control API: ${snapshot['controlApi']}\n'
        'Capabilities: ${snapshot['capabilities']}',
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ),
  );
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

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({required this.connection});

  final Map<String, Object?> connection;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text(connection['peerId'] as String),
    subtitle: Text(
      'state=${connection['state']} security=${connection['security']}\n'
      'endpoint=${connection['endpointId']} transport=${connection['transport']}\n'
      'session=${connection['sessionId']}',
      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
    ),
  );
}
