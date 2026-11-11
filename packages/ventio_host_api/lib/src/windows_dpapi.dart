import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Machine-protected envelope used only for a pending reissue delivery.
/// The database stores this ciphertext, never the replacement bearer token.
class WindowsDpapi {
  const WindowsDpapi();

  Uint8List protect(Uint8List plaintext, String operationId) =>
      _transform(plaintext, operationId, protect: true);

  Uint8List unprotect(Uint8List ciphertext, String operationId) =>
      _transform(ciphertext, operationId, protect: false);

  Uint8List _transform(
    Uint8List inputBytes,
    String operationId, {
    required bool protect,
  }) {
    if (!Platform.isWindows ||
        inputBytes.isEmpty ||
        inputBytes.length > 8192 ||
        !RegExp(r'^reissue_[0-9a-f]{32}$').hasMatch(operationId)) {
      throw StateError('Credential reissue protection is unavailable.');
    }
    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final inputBuffer = calloc<Uint8>(inputBytes.length);
    final entropyBytes = Uint8List.fromList(
      'Ventio credential reissue v1:$operationId'.codeUnits,
    );
    final entropyBuffer = calloc<Uint8>(entropyBytes.length);
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final protectData = crypt32
        .lookupFunction<
          Int32 Function(
            Pointer<_DataBlob>,
            Pointer<Utf16>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_DataBlob>,
          ),
          int Function(
            Pointer<_DataBlob>,
            Pointer<Utf16>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_DataBlob>,
          )
        >('CryptProtectData');
    final unprotectData = crypt32
        .lookupFunction<
          Int32 Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_DataBlob>,
          ),
          int Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_DataBlob>,
          )
        >('CryptUnprotectData');
    final localFree = kernel32
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final description = calloc<Pointer<Utf16>>();
    try {
      inputBuffer.asTypedList(inputBytes.length).setAll(0, inputBytes);
      entropyBuffer.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
      input.ref
        ..length = inputBytes.length
        ..data = inputBuffer;
      entropy.ref
        ..length = entropyBytes.length
        ..data = entropyBuffer;
      final succeeded = protect
          ? protectData(
              input,
              nullptr,
              entropy,
              nullptr,
              nullptr,
              0x5, // LOCAL_MACHINE | UI_FORBIDDEN
              output,
            )
          : unprotectData(
              input,
              description,
              entropy,
              nullptr,
              nullptr,
              0x1, // UI_FORBIDDEN
              output,
            );
      if (succeeded == 0 ||
          output.ref.data == nullptr ||
          output.ref.length <= 0 ||
          output.ref.length > 8192) {
        throw StateError('Credential reissue protection failed.');
      }
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      if (description.value != nullptr) {
        localFree(description.value.cast<Void>());
      }
      if (output.ref.data != nullptr) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
        localFree(output.ref.data.cast<Void>());
      }
      inputBuffer
          .asTypedList(inputBytes.length)
          .fillRange(0, inputBytes.length, 0);
      entropyBytes.fillRange(0, entropyBytes.length, 0);
      entropyBuffer
          .asTypedList(entropyBytes.length)
          .fillRange(0, entropyBytes.length, 0);
      calloc.free(description);
      calloc.free(entropyBuffer);
      calloc.free(inputBuffer);
      calloc.free(output);
      calloc.free(entropy);
      calloc.free(input);
    }
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int length;

  external Pointer<Uint8> data;
}
