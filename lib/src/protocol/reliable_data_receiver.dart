import 'application_payload.dart';
import '../types.dart';
import 'reassembly.dart';
import 'reliability.dart';

/// Result of accepting one authenticated DATA chunk. The owning connection
/// sends [acknowledgmentMessageId] only after the complete logical operation
/// has reached a delivered or duplicate-completed result.
class ReliableDataReceiveResult {
  const ReliableDataReceiveResult._(
      {this.delivered, this.acknowledgmentMessageId});
  const ReliableDataReceiveResult.incomplete() : this._();
  ReliableDataReceiveResult.delivered(
      ReassembledData delivered, List<int>? acknowledgmentMessageId)
      : this._(
            delivered: delivered,
            acknowledgmentMessageId:
                List<int>.unmodifiable(acknowledgmentMessageId ?? const []));
  ReliableDataReceiveResult.duplicate(List<int> acknowledgmentMessageId)
      : this._(
            acknowledgmentMessageId:
                List<int>.unmodifiable(acknowledgmentMessageId));

  final ReassembledData? delivered;
  final List<int>? acknowledgmentMessageId;
  bool get isDuplicate => delivered == null && acknowledgmentMessageId != null;
}

/// Section 23.3 DATA receiver. This is called only after an encrypted DATA
/// frame has passed frame validation. A conflicting completed MessageId throws
/// `MESSAGE_ID_COLLISION`; the owning PeerConnection applies its required
/// close transition.
class ReliableDataReceiver {
  ReliableDataReceiver(
      {DataReassembler? reassembler, CompletedMessageDedup? dedup})
      : _reassembler = reassembler ?? DataReassembler(),
        _dedup = dedup ?? CompletedMessageDedup();

  final DataReassembler _reassembler;
  final CompletedMessageDedup _dedup;

  ReliableDataReceiveResult add(List<int> messageId, DataChunk chunk) {
    final complete = _reassembler.add(messageId, chunk);
    if (complete == null) return const ReliableDataReceiveResult.incomplete();
    if (complete.deliveryMode != DeliveryMode.reliableAcked) {
      return ReliableDataReceiveResult.delivered(complete, null);
    }
    final firstCompletion = _dedup.accept(messageId, complete.bytes);
    return firstCompletion
        ? ReliableDataReceiveResult.delivered(complete, messageId)
        : ReliableDataReceiveResult.duplicate(messageId);
  }

  void onTransportGenerationLost() => _reassembler.onTransportGenerationLost();
}
