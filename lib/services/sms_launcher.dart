import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// Открывает системное приложение SMS с номером AGROFY и готовым текстом.
/// Приложение само ничего не отправляет: пользователь проверяет текст
/// и нажимает «Отправить».
class SmsLauncher {
  static const String numberKey = 'sms_number';

  /// Номер: «+» и от 3 до 15 цифр (короткие сервисные номера тоже).
  static bool validNumber(String number) =>
      RegExp(r'^\+?\d{3,15}$').hasMatch(number.replaceAll(RegExp(r'[\s()-]'), ''));

  static String normalize(String number) =>
      number.replaceAll(RegExp(r'[\s()-]'), '');

  /// iOS ожидает `sms:номер&body=`, Android — `sms:номер?body=`.
  static Uri composeUri(String number, String text, {bool? ios}) {
    final isIos = ios ?? Platform.isIOS;
    final body = Uri.encodeComponent(text);
    return Uri.parse('sms:${normalize(number)}${isIos ? '&' : '?'}body=$body');
  }

  static Future<bool> open(String number, String text) =>
      launchUrl(composeUri(number, text), mode: LaunchMode.externalApplication);
}
