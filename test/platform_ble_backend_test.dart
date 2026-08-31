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
