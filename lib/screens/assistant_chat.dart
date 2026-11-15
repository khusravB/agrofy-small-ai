import 'package:material_ui/material_ui.dart';

import '../ai/farm_assistant.dart';
import '../ai/llm_grounding.dart';
import '../ai/local_llm.dart';
import '../data/assistant_training.dart';

const _green = Color(0xFF276749);

class _Message {
  String text;
  final bool fromUser;
  String? source;

  /// Пояснение простыми словами от языковой модели.
  String? note;

  /// Пояснение ещё пишется языковой моделью.
  bool pending;

  _Message(
    this.text, {
    required this.fromUser,
    this.source,
    this.pending = false,
  });
}

/// Чат с офлайн-ассистентом. Ответы строятся на данных участка,
/// которые отдаёт [contextProvider].
class AssistantChat extends StatefulWidget {
  final AssistantContext Function() contextProvider;

  const AssistantChat({super.key, required this.contextProvider});

  @override
  State<AssistantChat> createState() => _AssistantChatState();
}

class _AssistantChatState extends State<AssistantChat>
    with AutomaticKeepAliveClientMixin {
  final _assistant = FarmAssistant();
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_Message> _messages = [];
  final _llm = LocalLlm.instance;

  /// Идёт генерация: новые вопросы ждут её окончания.
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _llm.addListener(_onLlmChanged);
    _llm.refresh();
  }

  @override
  void dispose() {
    _llm.removeListener(_onLlmChanged);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onLlmChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Пояснять моделью имеет смысл только ответы по данным участка:
  /// справку и непонятые вопросы показываем как есть.
  bool _shouldRephrase(AssistantAnswer answer) {
    return _llm.available &&
        answer.intent != null &&
        answer.intent != AssistantTraining.help &&
        answer.source != 'Вопрос не распознан' &&
        !answer.source.startsWith('Нет ');
  }

  Future<void> _ask(String question) async {
    final text = question.trim();
    if (text.isEmpty || _busy) {
      return;
    }

    final answer = _assistant.answer(text, widget.contextProvider());
    final rephrase = _shouldRephrase(answer);
    final reply = _Message(
      answer.text,
      fromUser: false,
      source: answer.source,
      pending: rephrase,
    );

    setState(() {
      _messages.add(_Message(text, fromUser: true));
      _messages.add(reply);
      _busy = rephrase;
    });
    _controller.clear();
    _scrollToEnd();

    if (!rephrase) {
      return;
    }

    // Точный ответ уже показан. Модель добавляет к нему короткое пояснение;
    // если она выдумала число, ушла от темы или сбилась с языка,
    // пояснение не показывается.
    final buffer = StringBuffer();
    var accepted = false;

    try {
      await for (final delta in _llm.generate(
        system: LlmGrounding.systemPrompt,
        user: LlmGrounding.userPrompt(text, answer.text),
        maxTokens: 110,
      )) {
        buffer.write(delta);
        if (!mounted) {
          return;
        }
        setState(() => reply.note = buffer.toString());
        _scrollToEnd();
      }

      accepted = LlmGrounding.isAcceptable(
        buffer.toString(),
        facts: answer.text,
        question: text,
      );
    } on Object {
      accepted = false;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      reply.pending = false;
      _busy = false;
      reply.note = accepted ? buffer.toString().trim() : null;
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        _ModelBanner(llm: _llm),
        Expanded(
          child: _messages.isEmpty
              ? _buildIntro()
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    return _Bubble(message: _messages[index]);
                  },
                ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final suggestion in FarmAssistant.suggestions)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(suggestion),
                    onPressed: () => _ask(suggestion),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _ask,
                  decoration: const InputDecoration(
                    hintText: 'Спросите про участок…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Отправить',
                style: IconButton.styleFrom(backgroundColor: _green),
                onPressed: _busy ? null : () => _ask(_controller.text),
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIntro() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy, size: 44, color: _green),
            SizedBox(height: 14),
            Text(
              'Офлайн-помощник',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Небольшая модель на вашем телефоне понимает вопрос и '
              'отвечает по данным участка, расчётам советника и базе '
              'знаний. Интернет не нужен, данные никуда не отправляются.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _Message message;

  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final fromUser = message.fromUser;

    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.84,
        ),
        decoration: BoxDecoration(
          color: fromUser ? _green : const Color(0xFFEFF3F0),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: fromUser ? Colors.white : Colors.black87,
                height: 1.4,
              ),
            ),
            if (message.pending || message.note != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Простыми словами · ${LocalLlm.modelName} на устройстве',
                      style: TextStyle(
                        color: _green,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      (message.note ?? '').isEmpty
                          ? 'Модель думает…'
                          : message.note!,
                      style: const TextStyle(height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
            if (message.source != null) ...[
              const SizedBox(height: 8),
              Text(
                'Источник: ${message.source}',
                style: const TextStyle(color: Colors.black45, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Состояние генеративной модели: скачать, прогресс, готова.
class _ModelBanner extends StatelessWidget {
  final LocalLlm llm;

  const _ModelBanner({required this.llm});

  @override
  Widget build(BuildContext context) {
    final status = llm.status;

    String title;
    String subtitle;
    Widget? action;

    switch (status) {
      case LlmStatus.unknown:
        return const SizedBox.shrink();
      case LlmStatus.notDownloaded:
      case LlmStatus.error:
        title = 'Языковая модель не скачана';
        subtitle = llm.error ??
            'Без неё ответы точные, но шаблонные. ${LocalLlm.modelName}, '
                'около ${LocalLlm.approxSizeMb} МБ: скачайте или возьмите '
                'файл с другого телефона.';
        action = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            TextButton(
              onPressed: llm.download,
              child: const Text('Скачать'),
            ),
            TextButton(
              onPressed: llm.importFromFile,
              child: const Text('Из файла'),
            ),
          ],
        );
      case LlmStatus.verifying:
        title = 'Проверка файла модели';
        subtitle = 'Сверяем размер и контрольную сумму с официальным файлом…';
        action = const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case LlmStatus.downloading:
        title = 'Скачивание модели: ${(llm.progress * 100).round()}%';
        subtitle = 'Можно продолжать пользоваться приложением.';
        action = TextButton(
          onPressed: llm.cancelDownload,
          child: const Text('Отмена'),
        );
      case LlmStatus.ready:
      case LlmStatus.loading:
      case LlmStatus.loaded:
        title = 'Языковая модель на устройстве';
        subtitle = status == LlmStatus.loading
            ? 'Загружается в память…'
            : '${LocalLlm.modelName} поясняет ответы простыми словами. '
                'Работает без сети.';
        action = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Передать модель на другой телефон',
              onPressed: llm.share,
              icon: const Icon(Icons.ios_share),
            ),
            IconButton(
              tooltip: 'Удалить модель с устройства',
              onPressed: status == LlmStatus.loading ? null : llm.delete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4EE),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory, color: _green, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              action,
            ],
          ),
          if (status == LlmStatus.downloading) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: LinearProgressIndicator(
                value: llm.progress,
                color: _green,
                backgroundColor: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
