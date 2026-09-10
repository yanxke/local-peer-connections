import 'package:flutter_test/flutter_test.dart';
import 'package:lpc_integration_device_app/device_test_controller.dart';
import 'package:lpc_integration_device_app/main.dart';

void main() {
  testWidgets('device test app renders raw LPC state', (tester) async {
    final controller = DeviceTestController(displayName: 'Test Device');
    addTearDown(controller.dispose);
    await tester.pumpWidget(DeviceTestApp(controller: controller));

    expect(find.text('LPC Device Test'), findsOneWidget);
    expect(find.textContaining('Runtime: notInitialized'), findsOneWidget);
    expect(find.textContaining('PeerId: null'), findsOneWidget);
  });
}
