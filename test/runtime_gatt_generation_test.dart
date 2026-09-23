import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/src/runtime.dart';

void main() {
  test('UT-261 stale GATT disconnect cannot own a newer generation', () {
    expect(gattConnectionGenerationMatches(7, 7), isTrue);
    expect(gattConnectionGenerationMatches(6, 7), isFalse);
    expect(gattConnectionGenerationMatches(null, 7), isTrue);
    expect(gattConnectionGenerationMatches(7, null), isTrue);
  });

  test('UT-266 stale cleanup is scoped to the generation being replaced', () {
    // Native close calls are generation-scoped by the runtime/backend API.
    // This is the contract used when Dart has already dropped the old
    // binding but the platform has not finished releasing its native handle.
    expect(gattConnectionGenerationMatches(12, 12), isTrue);
    expect(gattConnectionGenerationMatches(12, 13), isFalse);
  });
}
