# Сборка из корня репозитория (сервер зависит от packages/agrofy_core):
#   docker build -f server/Dockerfile -t agrofy-sms .
FROM dart:3.14 AS build
WORKDIR /src
COPY packages/agrofy_core/ packages/agrofy_core/
COPY server/pubspec.yaml server/pubspec.lock server/
WORKDIR /src/server
RUN dart pub get
COPY server/ /src/server/
RUN mkdir -p /out && dart pub get --offline && dart compile exe bin/server.dart -o /out/agrofy-sms

# Минимальный образ: только исполняемый файл и системные библиотеки Dart
# (включая корневые сертификаты для HTTPS-запросов к NASA и Twilio).
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/agrofy-sms /app/agrofy-sms
ENV PORT=8080 AGROFY_DATA_DIR=/data
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/app/agrofy-sms"]
