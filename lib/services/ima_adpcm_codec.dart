import 'dart:typed_data';

/// Compressed 4-bit IMA-ADPCM frame + metadata.
class AdpcmFrame {
  final int initialPredictor;
  final int initialStepIndex;
  final Uint8List nibbles;
  final bool isSilent;

  const AdpcmFrame({
    required this.initialPredictor,
    required this.initialStepIndex,
    required this.nibbles,
    required this.isSilent,
  });
}

/// Pure-Dart 4:1 IMA-ADPCM Audio Codec with Voice Activity Detection (VAD/DTX).
///
/// Converts 16-bit signed PCM samples (8 kHz mono) into 4-bit nibbles (4:1 ratio).
/// 40ms of speech (320 samples = 640 bytes PCM) compresses down to 160 bytes.
/// Silence suppression skips frames below energy threshold to save BLE airtime.
class ImaAdpcmCodec {
  static const List<int> _indexTable = [
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8,
  ];

  static const List<int> _stepTable = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
  ];

  int _encPredictor = 0;
  int _encStepIndex = 0;

  void resetEncoder() {
    _encPredictor = 0;
    _encStepIndex = 0;
  }

  /// Encodes little-endian 16-bit PCM bytes into a 4:1 ADPCM frame + VAD silence flag.
  AdpcmFrame encodePcm16(Uint8List pcmBytes, {int silenceRmsThreshold = 90}) {
    final bd = ByteData.sublistView(pcmBytes);
    final sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) {
      return AdpcmFrame(
        initialPredictor: 0,
        initialStepIndex: 0,
        nibbles: Uint8List(0),
        isSilent: true,
      );
    }

    // Compute simple average magnitude for fast VAD (avoids sending silence over BLE)
    int absSum = 0;
    for (int i = 0; i < sampleCount; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      absSum += s < 0 ? -s : s;
    }
    final avgAmp = absSum / sampleCount;
    final isSilent = avgAmp < silenceRmsThreshold;

    final startPredictor = _encPredictor;
    final startStepIndex = _encStepIndex;

    final outLen = (sampleCount + 1) ~/ 2;
    final out = Uint8List(outLen);

    for (int i = 0; i < sampleCount; i++) {
      final sample = bd.getInt16(i * 2, Endian.little);
      int step = _stepTable[_encStepIndex];
      int diff = sample - _encPredictor;
      int code = 0;

      if (diff < 0) {
        code = 8;
        diff = -diff;
      }

      int tempStep = step;
      if (diff >= tempStep) {
        code |= 4;
        diff -= tempStep;
      }
      tempStep >>= 1;
      if (diff >= tempStep) {
        code |= 2;
        diff -= tempStep;
      }
      tempStep >>= 1;
      if (diff >= tempStep) {
        code |= 1;
      }

      int delta = step >> 3;
      if ((code & 4) != 0) delta += step;
      if ((code & 2) != 0) delta += step >> 1;
      if ((code & 1) != 0) delta += step >> 2;
      if ((code & 8) != 0) delta = -delta;

      _encPredictor = (_encPredictor + delta).clamp(-32768, 32767);
      _encStepIndex = (_encStepIndex + _indexTable[code]).clamp(0, 88);

      final byteIdx = i >> 1;
      if ((i & 1) == 0) {
        out[byteIdx] = code & 0x0F;
      } else {
        out[byteIdx] |= (code & 0x0F) << 4;
      }
    }

    return AdpcmFrame(
      initialPredictor: startPredictor,
      initialStepIndex: startStepIndex,
      nibbles: out,
      isSilent: isSilent,
    );
  }

  /// Stateless decoder: decodes a received ADPCM frame back into 16-bit little-endian PCM bytes.
  static Uint8List decodeToPcm16({
    required int initialPredictor,
    required int initialStepIndex,
    required Uint8List nibbles,
  }) {
    final sampleCount = nibbles.length * 2;
    final pcm = Uint8List(sampleCount * 2);
    final bd = ByteData.sublistView(pcm);

    int predictor = initialPredictor.clamp(-32768, 32767);
    int stepIndex = initialStepIndex.clamp(0, 88);

    for (int i = 0; i < sampleCount; i++) {
      final byte = nibbles[i >> 1];
      final code = ((i & 1) == 0) ? (byte & 0x0F) : ((byte >> 4) & 0x0F);

      final step = _stepTable[stepIndex];
      int delta = step >> 3;
      if ((code & 4) != 0) delta += step;
      if ((code & 2) != 0) delta += step >> 1;
      if ((code & 1) != 0) delta += step >> 2;
      if ((code & 8) != 0) delta = -delta;

      predictor = (predictor + delta).clamp(-32768, 32767);
      stepIndex = (stepIndex + _indexTable[code]).clamp(0, 88);

      bd.setInt16(i * 2, predictor, Endian.little);
    }

    return pcm;
  }
}

