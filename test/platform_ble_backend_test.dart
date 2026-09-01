import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('platform BLE backend maps only local runtime capabilities', () async {
    const channel = MethodChannel('platform-ble-backend-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'queryCapabilities');
      return <Object?>['bleScan', 'bleAdvertise'];
    });
    final backend = PlatformBleBackend(methods: channel);
    final capabilities = await backend.queryCapabilities();
    expect(capabilities.contains(LocalRuntimeCapability.bleScan), isTrue);
    expect(capabilities.contains(LocalRuntimeCapability.bleAdvertise), isTrue);
    expect(capabilities.contains(LocalRuntimeCapability.gattCentral), isFalse);
  });

  test('advertising sends only service UUID and optional local name', () async {
    const channel = MethodChannel('platform-ble-advertise-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'startAdvertising');
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments.keys, containsAll(<String>['serviceUuid', 'localName']));
      expect(arguments['serviceUuid'], List.filled(16, 1));
      expect(arguments['localName'], 'LPC');
      return null;
    });
    await PlatformBleBackend(methods: channel)
        .startAdvertising(List.filled(16, 1), localName: 'LPC');
  });

  test('UT-001 canonical discovery filters solely by the service UUID',
      () async {
    const channel = MethodChannel('platform-ble-discovery-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'startDiscovery');
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments.keys, <String>['serviceUuid']);
      expect(arguments['serviceUuid'], List.filled(16, 1));
      return null;
    });
    await PlatformBleBackend(methods: channel)
        .startDiscovery(List.filled(16, 1));
  });

  test('GATT listener receives only the configured service UUID', () async {
    const channel = MethodChannel('platform-ble-gatt-listen-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listenGatt');
      expect(call.arguments, {'serviceUuid': List.filled(16, 1)});
      return null;
    });
    await PlatformBleBackend(methods: channel).listenGatt(List.filled(16, 1));
  });

  test('UT-160 GATT connect accepts only an opaque discovery endpoint ID',
      () async {
    const channel = MethodChannel('platform-ble-gatt-connect-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'connectGatt');
      expect(call.arguments, {'endpointId': 'platform-endpoint'});
      return null;
    });
    await PlatformBleBackend(methods: channel).connectGatt('platform-endpoint');
    expect(
        PlatformBleEvent.fromPlatform({
          'type': 'gattConnected',
          'endpointId': 'platform-endpoint',
          'localRole': 'central'
        }),
        isA<PlatformGattConnected>());
  });

  test('UT-161 platform GATT fragment outcome maps Section 44 states',
      () async {
    const channel = MethodChannel('platform-ble-gatt-fragment-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'submitGattFragment');
      expect((call.arguments as Map)['transmission'], 'writeWithoutResponse');
      return 'temporarilyUnavailable';
    });
    final platform = PlatformGattFragmentPlatform(
      backend: PlatformBleBackend(methods: channel),
      endpointId: 'platform-endpoint',
      platformSafeWriteSize: 20,
    );
    expect(
        await platform.submitGattFragment(Uint8List.fromList([1]),
            transmission: GattFragmentTransmission.writeWithoutResponse),
        GattFragmentSubmission.temporarilyUnavailable);
  });

  test('native GATT fragment remains connection-scoped bytes', () {
    final event = PlatformBleEvent.fromPlatform({
      'type': 'gattFragment',
      'endpointId': 'platform-endpoint',
      'bytes': [1, 2]
    });
    expect(event, isA<PlatformGattFragment>());
    expect((event as PlatformGattFragment).bytes, [1, 2]);
  });

  test('GATT terminal and writable events remain transport-scoped', () {
    expect(
        PlatformBleEvent.fromPlatform(
            {'type': 'gattDisconnected', 'endpointId': 'native-id'}),
        isA<PlatformGattDisconnected>());
    expect(PlatformBleEvent.fromPlatform({'type': 'gattWritable'}),
        isA<PlatformGattWritable>());
  });

  test('native backend errors map to stable LPC errors', () async {
    const channel = MethodChannel('platform-ble-error-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'BLUETOOTH_POWERED_OFF');
    });
    await expectLater(
        PlatformBleBackend(methods: channel).startDiscovery(List.filled(16, 1)),
        throwsA(isA<LpcException>().having(
            (error) => error.code, 'code', LpcErrorCode.bluetoothPoweredOff)));
  });

  test('discovery endpoint event is explicitly not a protocol PeerId', () {
    final event = PlatformBleEvent.fromPlatform(
        {'type': 'endpointFound', 'endpointId': 'native-id', 'rssi': -50});
    expect(event, isA<PlatformEndpointFound>());
    expect((event as PlatformEndpointFound).endpointId, 'native-id');
  });
}
