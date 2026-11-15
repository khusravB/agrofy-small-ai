import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'model_file_check.dart';

enum LlmStatus {
  unknown,
  notDownloaded,
  downloading,
  verifying,
  ready,
  loading,
  loaded,
  error,
}

/// Small AI №3: генеративная языковая модель на устройстве.
///
/// Qwen2.5-0.5B-Instruct (GGUF, Apache 2.0) через llama.cpp. Файл модели
/// скачивается один раз по кнопке и хранится в приложении; дальше модель
/// работает без сети, а вопросы и данные участка не покидают телефон.
class LocalLlm extends ChangeNotifier {
  static final LocalLlm instance = LocalLlm._();

  LocalLlm._();

  static const String modelName = 'Qwen2.5-0.5B';
  static const String fileName = 'qwen2.5-0.5b-instruct-q4_k_m.gguf';
  static const String modelUrl =
      'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/'
      '$fileName';
  static const int approxSizeMb = 491;

  /// Размер и SHA-256 официального файла (Hugging Face, Qwen).
  static const int expectedBytes = 491400032;
  static const String expectedSha256 =
      '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db';

  /// Файл меньше этого размера считается недокачанным.
  static const int _minValidBytes = 400 * 1024 * 1024;

  LlmStatus _status = LlmStatus.unknown;
  double _progress = 0;
  String? _error;
  LlamaEngine? _engine;
  http.Client? _downloadClient;

  LlmStatus get status => _status;

  /// Доля скачанного файла, 0–1.
  double get progress => _progress;

  String? get error => _error;

  /// Модель скачана и ею можно пользоваться.
  bool get available =>
      _status == LlmStatus.ready ||
      _status == LlmStatus.loading ||
      _status == LlmStatus.loaded;

  void _set(LlmStatus status, {String? error}) {
    _status = status;
    _error = error;
    notifyListeners();
  }

  Future<File> _modelFile() async {
    final directory = await getApplicationSupportDirectory();
    final models = Directory('${directory.path}/models');
    if (!models.existsSync()) {
      models.createSync(recursive: true);
    }
    return File('${models.path}/$fileName');
  }

  /// Проверяет, есть ли файл модели на устройстве.
  Future<void> refresh() async {
    if (_status == LlmStatus.downloading ||
        _status == LlmStatus.verifying ||
        _status == LlmStatus.loading ||
        _status == LlmStatus.loaded) {
      return;
    }

    try {
      final file = await _modelFile();
      final valid = file.existsSync() && file.lengthSync() >= _minValidBytes;
      _set(valid ? LlmStatus.ready : LlmStatus.notDownloaded);
    } on Object {
      // Например, в тестах без платформенных плагинов.
      _set(LlmStatus.notDownloaded);
    }
  }

  /// Скачивает файл модели. Нужен интернет и около 500 МБ места.
  Future<void> download() async {
    if (_status == LlmStatus.downloading) {
      return;
    }

    _progress = 0;
    _set(LlmStatus.downloading);

    final client = http.Client();
    _downloadClient = client;

    try {
      final file = await _modelFile();
      final part = File('${file.path}.part');

      final response = await client.send(
        http.Request('GET', Uri.parse(modelUrl)),
      );
      if (response.statusCode != 200) {
        throw HttpException('Код ответа ${response.statusCode}');
      }

      final total = response.contentLength ?? approxSizeMb * 1024 * 1024;
      final sink = part.openWrite();
      var received = 0;
      var lastNotified = 0.0;

      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          _progress = (received / total).clamp(0.0, 1.0);

          if (_progress - lastNotified >= 0.01) {
            lastNotified = _progress;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }

      if (received < _minValidBytes) {
        throw const HttpException('Файл скачан не полностью');
      }

      _set(LlmStatus.verifying);
      final problem = await ModelFileCheck.verify(
        part,
        expectedBytes: expectedBytes,
        expectedSha256: expectedSha256,
      );
      if (problem != null) {
        await part.delete();
        _set(LlmStatus.error, error: problem);
        return;
      }

      await part.rename(file.path);
      _set(LlmStatus.ready);
    } on Object catch (error) {
      _set(
        LlmStatus.error,
        error: _downloadClient == null
            ? 'Загрузка отменена.'
            : 'Не удалось скачать модель: $error',
      );
    } finally {
      client.close();
      _downloadClient = null;
    }
  }

  /// Берёт файл модели с карты памяти, из «Файлов» или полученный по
  /// AirDrop/Bluetooth: один раз скачал агроном — раздал остальным.
  Future<void> importFromFile() async {
    final picked = await FilePicker.pickFile(type: FileType.any);
    final path = picked?.path;
    if (path == null) {
      return;
    }

    _set(LlmStatus.verifying);
    try {
      final source = File(path);
      final problem = await ModelFileCheck.verify(
        source,
        expectedBytes: expectedBytes,
        expectedSha256: expectedSha256,
      );
      if (problem != null) {
        _set(LlmStatus.error, error: problem);
        return;
      }

      final target = await _modelFile();
      await source.copy(target.path);
      _set(LlmStatus.ready);
    } on Object catch (error) {
      _set(LlmStatus.error, error: 'Не удалось взять модель из файла: $error');
    }
  }

  /// Передаёт файл модели на другой телефон через системное меню
  /// (AirDrop, Bluetooth, Nearby Share, карта памяти).
  Future<void> share() async {
    final file = await _modelFile();
    if (!file.existsSync()) {
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'Модель $modelName для AGROFY: на другом телефоне откройте '
            'AI → Вопросы → «Из файла».',
      ),
    );
  }

  void cancelDownload() {
    final client = _downloadClient;
    _downloadClient = null;
    client?.close();
  }

  /// Удаляет файл модели и освобождает память.
  Future<void> delete() async {
    await unload();
    final file = await _modelFile();
    if (file.existsSync()) {
      file.deleteSync();
    }
    _set(LlmStatus.notDownloaded);
  }

  Future<void> unload() async {
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
    if (_status == LlmStatus.loaded) {
      _set(LlmStatus.ready);
    }
  }

  Future<LlamaEngine> _ensureLoaded() async {
    final loaded = _engine;
    if (loaded != null) {
      return loaded;
    }

    _set(LlmStatus.loading);

    try {
      final file = await _modelFile();
      final engine = await LlamaEngine.load(
        LlamaModel(ModelSource.path(file.path)),
        params: const ModelParams(contextSize: 2048),
      );
      _engine = engine;
      _set(LlmStatus.loaded);
      return engine;
    } on Object catch (error) {
      _set(LlmStatus.error, error: 'Не удалось запустить модель: $error');
      rethrow;
    }
  }

  /// Генерирует ответ по частям. Модель загружается в память при первом
  /// вызове.
  Stream<String> generate({
    required String system,
    required String user,
    int maxTokens = 220,
  }) async* {
    final engine = await _ensureLoaded();

    yield* engine
        .create(
          [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.system,
              text: system,
            ),
            LlamaChatMessage.fromText(role: LlamaChatRole.user, text: user),
          ],
          params: GenerationParams(
            maxTokens: maxTokens,
            temp: 0.3,
            topP: 0.9,
            penalty: 1.1,
          ),
        )
        .textDeltas();
  }

  void cancelGeneration() => _engine?.cancelGeneration();
}
