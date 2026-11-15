import 'dart:io';

import 'package:crypto/crypto.dart';

/// Проверка файла модели перед использованием: размер, сигнатура GGUF
/// и контрольная сумма SHA-256 официального файла. Защищает и от
/// недокачанного файла, и от подменённого при передаче между телефонами.
class ModelFileCheck {
  static Future<String?> verify(
    File file, {
    required int expectedBytes,
    required String expectedSha256,
  }) async {
    if (!file.existsSync()) {
      return 'Файл не найден.';
    }

    final size = await file.length();
    if (size != expectedBytes) {
      return 'Размер файла ${(size / 1e6).round()} МБ, ожидалось '
          '${(expectedBytes / 1e6).round()} МБ — это другая модель или файл '
          'повреждён.';
    }

    final handle = await file.open();
    final magic = await handle.read(4);
    await handle.close();
    if (String.fromCharCodes(magic) != 'GGUF') {
      return 'Это не файл модели GGUF.';
    }

    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != expectedSha256) {
      return 'Контрольная сумма не совпала — файл изменён или повреждён. '
          'Возьмите файл из официального источника.';
    }

    return null;
  }
}
