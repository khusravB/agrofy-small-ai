import 'package:material_ui/material_ui.dart';

import '../ai/farm_assistant.dart';

const _green = Color(0xFF276749);

class _Message {
  final String text;
  final bool fromUser;
  final String? source;

  const _Message(this.text, {required this.fromUser, this.source});
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

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _ask(String question) {
    final text = question.trim();
    if (text.isEmpty) {
      return;
    }

    final answer = _assistant.answer(text, widget.contextProvider());

    setState(() {
      _messages.add(_Message(text, fromUser: true));
      _messages.add(
        _Message(answer.text, fromUser: false, source: answer.source),
      );
    });
    _controller.clear();

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
                onPressed: () => _ask(_controller.text),
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
