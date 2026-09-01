import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-030 UPGRADE_BIND uses the exact Section 28.4 proof vector',
      () async {
    final proof = await upgradeBindProof(
        resumeSecret: List.filled(32, 1),
        upgradeId: List.filled(16, 2),
        sessionId: List.filled(16, 3),
        targetTransport: UpgradeTransport.wifiLanTcp,
        targetGeneration: 2);
    expect(_hex(proof),
        'fa7efe76a65270ddc675241941d0a16fe4383b6c829c31485740780b2f0f115d');
    final bind = UpgradeBind(
        upgradeId: List.filled(16, 2),
        sessionId: List.filled(16, 3),
        targetTransport: UpgradeTransport.wifiLanTcp,
        targetGeneration: 2,
        bindingProof: proof);
    await verifyUpgradeBindProof(
        resumeSecret: List.filled(32, 1),
        bind: UpgradeBind.decode(bind.encode()));
  });

  test('UPGRADE_OFFER and ACCEPT use the frozen shared proposal layout', () {
    final offer = UpgradeOffer(
        upgradeId: List.filled(16, 1),
        targetTransport: UpgradeTransport.wifiLanTcp,
        targetGeneration: 2,
        offerData: [9, 8, 7]);
    expect(offer.encode(), [
      ...List.filled(16, 1),
      3, 0, 0, 0, // transport and reserved bytes
      0, 0, 0, 2, // target generation
      0, 3, // data length
      9, 8, 7,
    ]);
    final parsed = UpgradeAccept.decode(UpgradeAccept(
        upgradeId: List.filled(16, 1),
        targetTransport: UpgradeTransport.wifiLanTcp,
        targetGeneration: 2,
        acceptData: [6]).encode());
    expect(parsed.acceptData, [6]);
    expect(parsed.targetGeneration, 2);
  });

  test('UPGRADE_REJECT preserves the exact stable error code', () {
    final reject = UpgradeReject(
        upgradeId: List.filled(16, 1), errorCode: LpcErrorCode.lanUnavailable);
    expect(UpgradeReject.decode(reject.encode()).errorCode,
        LpcErrorCode.lanUnavailable);
  });

  test('LAN TCP upgrade data has the exact address-family layout', () {
    final ipv4 = LanTcpEndpoint(
        addressFamily: 4,
        port: 1234,
        address: [192, 168, 1, 2, ...List.filled(12, 0)]);
    expect(ipv4.encode(), [4, 4, 210, 192, 168, 1, 2, ...List.filled(12, 0)]);
    expect(LanTcpEndpoint.decode(ipv4.encode()).port, 1234);
    expect(
        () => LanTcpEndpoint(
            addressFamily: 4, port: 1, address: List.filled(16, 1)),
        throwsA(isA<LpcException>()));
  });

  test('L2CAP PSM offer data is exactly uint16 big-endian', () {
    expect(L2capPsm(0x1234).encode(), [0x12, 0x34]);
    expect(L2capPsm.decode([0x12, 0x34]).value, 0x1234);
  });

  test('UPGRADE_BIND_ACK and SWITCH payloads have frozen layouts', () {
    final id = List.filled(16, 1);
    expect(
        UpgradeBindAck.decode(
                UpgradeBindAck(upgradeId: id, targetGeneration: 2).encode())
            .targetGeneration,
        2);
    expect(
        UpgradeSwitch.decode(UpgradeSwitch(
                    upgradeId: id,
                    targetGeneration: 2,
                    targetTransport: UpgradeTransport.bleL2cap)
                .encode())
            .targetTransport,
        UpgradeTransport.bleL2cap);
  });

  test('UT-031 pre-switch failure leaves old transport and generation active',
      () {
    final upgrade = UpgradeLifecycle(
        activeTransport: UpgradeTransport.bleGatt, currentGeneration: 1);
    upgrade.offer(UpgradeTransport.bleL2cap, targetGeneration: 2);
    upgrade.accept();
    upgrade.candidateConnecting();
    expect(upgrade.failBeforeSwitch(), UpgradeFailureAction.retainOldTransport);
    expect(upgrade.activeTransport, UpgradeTransport.bleGatt);
    expect(upgrade.currentGeneration, 1);
    expect(upgrade.state, UpgradeState.failed);
  });

  test('UT-032 post-switch failure requires RESUME and never rolls back', () {
    final upgrade = UpgradeLifecycle(
        activeTransport: UpgradeTransport.bleGatt, currentGeneration: 1);
    upgrade.offer(UpgradeTransport.wifiLanTcp, targetGeneration: 2);
    upgrade.accept();
    upgrade.candidateConnecting();
    upgrade.candidateOpened();
    upgrade.localBindSent();
    upgrade.remoteBindVerified();
    upgrade.remoteBindAckReceived();
    upgrade.switchAcknowledged();
    upgrade.switchActivated();

    expect(upgrade.activeTransportFailed(),
        UpgradeFailureAction.secureResumeFallback);
    expect(upgrade.activeTransport, UpgradeTransport.wifiLanTcp);
    expect(upgrade.currentGeneration, 2);
    expect(upgrade.state, UpgradeState.failed);
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
