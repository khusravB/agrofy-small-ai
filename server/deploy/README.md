# Развёртывание: VPS + Vonage или Twilio

Сервер AGROFY SMS и Caddy (HTTPS) в Docker на одном VPS, SMS через номер
Vonage или Twilio. Время: около часа. Шаги с аккаунтами и оплатой делаете вы
сами.

## 0. Что важно знать про Таджикистан

- **Twilio**: по [правилам Twilio](https://www.twilio.com/en-us/guidelines/tj/sms)
  двусторонние SMS в Таджикистане не поддерживаются и местных номеров нет.
  Ответы абонентам MegaFon приходят с подменённым буквенным отправителем.
- **Vonage**: местных номеров тоже нет; отправка в Таджикистан работает, а
  прохождение SMS с таджикских SIM на зарубежный номер Vonage нигде не
  гарантировано — проверяется только тестом.

В обоих случаях номер AGROFY зарубежный: SMS на него с таджикской SIM —
международное, дороже обычного и не у всех операторов проходит. Для демо этого
хватает; перед съёмкой проверьте канал с SIM каждого нужного оператора. Для
работы с фермерами нужен местный шлюз или договор с оператором (провайдер
`generic`, см. `server/README.md`).

## 1. VPS

- Любой провайдер, Ubuntu 24.04, 1 vCPU и 1–2 ГБ RAM.
- Вход по SSH; открыты порты 22, 80 и 443.
- Домен не обязателен: подойдёт `<IP>.sslip.io`, например
  `203.0.113.10.sslip.io`. Caddy сам получит сертификат Let's Encrypt.

**Google Cloud**: Compute Engine → VM, e2-small (или e2-micro со swap),
Ubuntu 24.04, отметить Allow HTTP и Allow HTTPS, внешний IP сделать
статическим. Команду `ufw` ниже можно пропустить — порты закрывает файрвол
Google. Cloud Run не подходит: серверу нужен постоянный диск.

На сервере:

```bash
curl -fsSL https://get.docker.com | sh
```

```bash
sudo usermod -aG docker $USER && newgrp docker
```

```bash
sudo ufw allow OpenSSH && sudo ufw allow 80,443/tcp && sudo ufw enable
```

```bash
git clone https://github.com/khusravB/agrofy-small-ai.git && cd agrofy-small-ai/server/deploy
```

На машине с 1 ГБ памяти сначала добавьте swap, иначе сборка может не
поместиться:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
```

## 2a. Vonage

1. Зарегистрируйтесь на vonage.com (Communications APIs; пароль и коды
   вводите сами).
2. **API Settings**: скопируйте **API key**, **API secret** и **Signature
   secret**. Там же в **SMS settings** выберите **Messages API** — иначе
   входящие придут в другом формате.
3. **Numbers → Buy numbers**: номер с функцией SMS.
4. **Applications → Create a new application**: включите **Messages**,
   - Inbound URL: `https://<AGROFY_DOMAIN>/sms/vonage`
   - Status URL: `https://<AGROFY_DOMAIN>/sms/vonage/status`

   Если форма требует ключи — нажмите «Generate public and private key»;
   приватный ключ серверу не нужен, просто сохраните его в надёжном месте.
   Затем **Link** — привяжите купленный номер к приложению.
5. На пробном аккаунте Vonage отправляет SMS только на номера, добавленные
   как тестовые, — добавьте свой телефон.

## 2b. Twilio

1. Зарегистрируйтесь на twilio.com.
2. **Phone Numbers → Buy a number**: номер с возможностью SMS.
3. **Messaging → Settings → Geo permissions**: включите Таджикистан.
4. На пробном аккаунте: **Phone Numbers → Verified Caller IDs** — добавьте
   номера, с которых будете писать.
5. **Account Info**: Account SID и Auth Token.
6. **Phone Numbers → Active numbers** → номер → **A message comes in**:
   Webhook, `https://<AGROFY_DOMAIN>/sms/twilio`, HTTP POST → Save.

## 3. Настройки

```bash
cp .env.example .env && chmod 600 .env && nano .env
```

Заполните `AGROFY_DOMAIN`, `AGROFY_SMS_PROVIDER` (`vonage` или `twilio`),
ключи выбранного провайдера и `AGROFY_AUDIT_SALT`. Соль:

```bash
openssl rand -hex 32
```

Файл `.env` не коммитится и не должен попадать в чаты или скриншоты.

## 4. Запуск

```bash
docker compose up -d --build
```

Первая сборка занимает 3–5 минут. Проверка — должно вернуться `ok`:

```bash
curl https://<AGROFY_DOMAIN>/health
```

Если сервер не запустился, в журнале написано, какой настройки не хватает:

```bash
docker compose logs agrofy
```

Частые сообщения в журнале:

| Сообщение | Что значит |
|---|---|
| `Отклонён вебхук: missing jwt` | Vonage шлёт неподписанные вебхуки: проверьте, что приложение использует Messages API |
| `Отклонён вебхук: bad signature` | Неверный `VONAGE_SIGNATURE_SECRET`, `TWILIO_AUTH_TOKEN`, или адрес в Twilio не совпадает с `AGROFY_DOMAIN` |
| `Vonage: 401` / `Twilio: 401` | Неверные API-ключи |
| `Vonage: 403` или `422` | Пробный аккаунт: номер получателя не добавлен как тестовый, либо отправка в страну не разрешена |

## 5. Проверка

1. Отправьте на номер AGROFY `HELP` — придёт список команд.
2. `REG F1 40.28,69.62 ХЛОПОК`, затем вопрос «Когда сеять хлопок?».
3. `FIELD F1 NDVI 90D` — сначала придёт подтверждение, через 1–2 минуты SMS со
   ссылкой на пакет.
4. В приложении: AI → Советник → «SMS и спутниковые данные» → «Изменить» —
   укажите номер AGROFY.

Twilio по умолчанию сам обрабатывает английские STOP, START и HELP; русские
СТОП и ПОМОЩЬ обрабатывает сервер.

## Обслуживание

| Задача | Команда (в `server/deploy`) |
|---|---|
| Обновить | `git pull && docker compose up -d --build` |
| Журнал | `docker compose logs -f agrofy` |
| Остановить | `docker compose down` (данные в томе `agrofy-data` сохраняются) |
| Резервная копия | `docker run --rm -v deploy_agrofy-data:/d -v "$PWD":/b alpine tar czf /b/agrofy-data.tgz -C /d .` |

Стоимость: VPS — от нескольких долларов в месяц; у Vonage и Twilio платный
номер плюс каждое SMS в обе стороны, по их текущему прайсу. Если ключ API
когда-либо засветился, перевыпустите его в панели провайдера и обновите `.env`.
