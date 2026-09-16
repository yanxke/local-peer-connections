import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UDP probe sends immediately and then every 250 ms', () {
    final probes =
        UdpProbeController(nowMs: 0, nextToken: () => List<int>.filled(16, 7));
    expect(probes.poll(0), isA<UdpProbeSend>());
    expect(probes.poll(249), isA<UdpProbeNoAction>());
    expect(probes.poll(250), isA<UdpProbeSend>());
  });

  test('UDP probe activates only after remote probe and matching own ACK', () {
    final probes =
        UdpProbeController(nowMs: 0, nextToken: () => List<int>.filled(16, 7));
    final ack = probes.receiveProbe(List<int>.filled(16, 3));
    expect(ack, isA<UdpProbeAck>());
    expect((ack as UdpProbeAck).payload, List<int>.filled(16, 3));
    expect(probes.state, UdpProbeState.probing);
    probes.receiveProbeAck(List<int>.filled(16, 6));
    expect(probes.state, UdpProbeState.probing);
    probes.receiveProbeAck(List<int>.filled(16, 7));
    expect(probes.state, UdpProbeState.active);
  });

  test('UDP probe emits exactly eight transmissions before 2000 ms timeout',
      () {
    final probes =
        UdpProbeController(nowMs: 0, nextToken: () => List<int>.filled(16, 7));
    for (var nowMs = 0; nowMs < 2000; nowMs += 250) {
      expect(probes.poll(nowMs), isA<UdpProbeSend>());
    }
    expect(probes.poll(1999), isA<UdpProbeNoAction>());
    expect(probes.poll(2000), isA<UdpProbeFailed>());
    expect(probes.state, UdpProbeState.failed);
    expect(
        probes.receiveProbe(List<int>.filled(16, 1)), isA<UdpProbeNoAction>());
  });
}
