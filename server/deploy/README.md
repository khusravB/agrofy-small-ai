# Развёртывание: VPS + Twilio

Сервер AGROFY SMS и Caddy (HTTPS) в Docker на одном VPS, SMS через номер Twilio.
Время: около часа. Шаги с аккаунтами и оплатой делаете вы сами.

## 0. Что важно знать про Twilio и Таджикистан

По [правилам Twilio для Таджикистана](https://www.twilio.com/en-us/guidelines/tj/sms)
двусторонние SMS там не поддерживаются и местных номеров нет. Поэтому:

- номер AGROFY будет зарубежным (например, американским). SMS на него с
  таджикской SIM — международное: дороже обычного и не у всех операторов
  проходит;
- ответы Twilio абонентам MegaFon приходят с подменённым буквенным
  отправителем, и на такое SMS нельзя ответить. Новый вопрос пишется на номер
  AGROFY, сохранённый в приложении (кнопка «Спросить по SMS» так и делает);
- на пробном аккаунте ответы приходят только на номера, подтверждённые в
  Twilio, и в начале каждого SMS стоит приписка Twilio.

Для демо на хакатоне этого хватает. Перед съёмкой проверьте канал с SIM
каждого нужного оператора. Для работы с фермерами нужен местный шлюз или
договор с оператором (см. `server/README.md`, провайдер `generic`).

## 1. VPS

- Любой провайдер, Ubuntu 24.04, 1 vCPU и 1 ГБ RAM достаточно.
- Вход по SSH-ключу; открыть порты 22, 80 и 443.
- Домен не обязателен: подойдёт `<IP>.sslip.io`, например
  `203.0.113.10.sslip.io`. Caddy сам получит сертификат Let's Encrypt.

На сервере:

```bash
curl -fsSL https://get.docker.com | sh
```

```bash
sudo ufw allow OpenSSH && sudo ufw allow 80,443/tcp && sudo ufw enable
```

```bash
git clone https://github.com/khusravB/agrofy-small-ai.git && cd agrofy-small-ai/server/deploy
```

## 2. Twilio

1. Зарегистрируйтесь на twilio.com (пароль и коды вводите сами).
2. **Phone Numbers → Buy a number**: номер с возможностью SMS.
3. **Messaging → Settings → Geo permissions**: включите Таджикистан, иначе
   ответы туда не уйдут.
4. На пробном аккаунте: **Phone Numbers → Verified Caller IDs** — добавьте
   номера, с которых будете писать.
5. Из **Account Info** понадобятся Account SID и Auth Token.

## 3. Настройки

```bash
cp .env.example .env && chmod 600 .env && nano .env
```

Заполните `AGROFY_DOMAIN`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`,
`TWILIO_FROM` (купленный номер, `+1…`) и `AGROFY_AUDIT_SALT`. Соль можно
получить командой:

```bash
openssl rand -hex 32
```

Файл `.env` не коммитится и не должен попадать в чаты или скриншоты.

## 4. Запуск

```bash
docker compose up -d --build
```

Проверка (на сервере или с телефона в браузере): должно вернуться `ok`.

```bash
curl https://<AGROFY_DOMAIN>/health
```

Если сервер не запустился, в журнале будет написано, какой настройки не
хватает:

```bash
docker compose logs agrofy
```

## 5. Подключить номер к серверу

Twilio Console → **Phone Numbers → Active numbers** → ваш номер →
**Messaging configuration** → **A message comes in**: Webhook,
`https://<AGROFY_DOMAIN>/sms/twilio`, HTTP POST → Save.

`AGROFY_DOMAIN` должен точно совпадать с адресом в Twilio: по нему
проверяется подпись, и при расхождении сервер отвечает 403.

## 6. Проверка

1. С подтверждённого телефона отправьте на номер Twilio `HELP` — придёт
   список команд.
2. `REG F1 40.28,69.62 ХЛОПОК`, затем вопрос «Когда сеять хлопок?».
3. `FIELD F1 NDVI 90D` — сначала придёт подтверждение, через 1–2 минуты SMS со
   ссылкой на пакет.
4. В приложении: AI → Советник → «SMS и спутниковые данные» → «Изменить» —
   укажите номер Twilio.

По умолчанию Twilio сам обрабатывает английские STOP, START и HELP;
русские СТОП и ПОМОЩЬ обрабатывает сервер.

## Обслуживание

| Задача | Команда (в `server/deploy`) |
|---|---|
| Обновить | `git pull && docker compose up -d --build` |
| Журнал | `docker compose logs -f agrofy` |
| Остановить | `docker compose down` (данные в томе `agrofy-data` сохраняются) |
| Резервная копия | `docker run --rm -v deploy_agrofy-data:/d -v "$PWD":/b alpine tar czf /b/agrofy-data.tgz -C /d .` |

Стоимость: VPS обычно от нескольких долларов в месяц; у Twilio платный номер
плюс каждое SMS в обе стороны, по их текущему прайсу. Если Auth Token
когда-либо засветился, перевыпустите его в Twilio Console и обновите `.env`.
