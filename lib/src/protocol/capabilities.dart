import '../types.dart';

/// Section 49.1 capability bits permitted in a protocol-minor-0 HELLO.
enum PeerCapability {
  gattBaseline(0),
  l2capCoc(1),
  lanTcp(2),
  resume(3),
  transportUpgrade(4),
  remoteAck(5),
  realtimeLatest(6),
  autoCoordinator(7),
  lanUdpRealtime(8);

  const PeerCapability(this.bit);
  final int bit;
}

/// Wire-visible HELLO bitmap. Bits 9 through 31 are rejected rather than
/// silently masked, preserving the minor-0 reserved-bit rule.
class PeerCapabilityBitmap {
  PeerCapabilityBitmap(Iterable<PeerCapability> capabilities)
      : value = capabilities.fold(
            0, (bits, capability) => bits | (1 << capability.bit));
  PeerCapabilityBitmap.fromValue(this.value) {
    if (value < 0 || value & ~0x1ff != 0) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'reserved peer capability bit');
    }
  }
  final int value;
  bool contains(PeerCapability capability) =>
      value & (1 << capability.bit) != 0;
}

/// Section 49.2 API-only runtime bitmap. It intentionally has a different
/// type from [PeerCapabilityBitmap] and is never accepted by HELLO codecs.
enum LocalRuntimeCapability {
  bleScan(0),
  bleAdvertise(1),
  gattCentral(2),
  gattPeripheral(3),
  l2capConnect(4),
  l2capListen(5),
  lanDiscover(6),
  lanListen(7),
  lanConnect(8),
  secureIdentityStorage(9),
  lanUdp(10);

  const LocalRuntimeCapability(this.bit);
  final int bit;
}

class LocalRuntimeCapabilityBitmap {
  LocalRuntimeCapabilityBitmap(Iterable<LocalRuntimeCapability> capabilities)
      : value = capabilities.fold(
            0, (bits, capability) => bits | (1 << capability.bit));
  final int value;
  bool contains(LocalRuntimeCapability capability) =>
      value & (1 << capability.bit) != 0;
}
