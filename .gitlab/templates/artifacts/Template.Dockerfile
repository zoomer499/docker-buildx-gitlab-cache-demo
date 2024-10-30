# Шаблон Dockerfile для .NET приложений на базе Alpine

# Задаем теги образов и параметры для сборки
ARG ALPINE_IMAGE_TAG=latest
ARG DOCKER_REGISTRY=docker.io
ARG BASE_IMAGE=alpine
ARG BASE_IMAGE_TAG=latest
ARG BASE_BUILDER_IMAGE=$DOCKER_REGISTRY/custom-images/dotnet-sdk:$CONTAINER_OS
ARG DOTNET_CONFIGURATION=Release
ARG DOTNET_RUNTIME=linux-musl-x64
ARG CONTAINER_OS=$DOTNET_VERSION-alpine$ALPINE_IMAGE_TAG-amd64
ARG BACKEND_FOLDER=./backend
ARG BACKEND_FOLDER_SRC=src
ARG BUILD_ARTIFACTS_FOLDER=./build_artifacts/
ARG PROJECT_FOLDER
ARG PROJECT_CSPROJ_FILE

## Шаг 1: Восстановление зависимостей
FROM $BASE_BUILDER_IMAGE AS restore-env
ARG BACKEND_FOLDER=./backend
ARG PROJECT_FOLDER
WORKDIR /restore
# Копируем файлы проекта в контейнер для восстановления зависимостей
COPY ./${BACKEND_FOLDER} /restore/${BACKEND_FOLDER}
# Устанавливаем необходимый инструмент dotnet-subset
RUN dotnet tool install --global --no-cache dotnet-subset --version 0.3.2
# Восстанавливаем зависимости с использованием dotnet subset
RUN dotnet subset restore ${BACKEND_FOLDER}/*.sln --root-directory /restore --output restore_subset/

## Шаг 2: Сборка проекта
FROM $BASE_BUILDER_IMAGE AS builder
ARG DOTNET_CONFIGURATION=Release
ARG DOTNET_RUNTIME=linux-musl-x64
ARG BACKEND_FOLDER=./backend
ARG BUILD_ARTIFACTS_FOLDER=build_artifacts
ARG PROJECT_FOLDER
WORKDIR /build
# Копируем восстановленные зависимости из предыдущего шага
COPY --from=restore-env /restore/restore_subset/${BACKEND_FOLDER} .
# Выполняем восстановление проекта
RUN dotnet restore . --runtime ${DOTNET_RUNTIME}

# Копируем оставшиеся файлы проекта и компилируем
COPY ./${BACKEND_FOLDER}/ ./
RUN dotnet publish ./${BACKEND_FOLDER_SRC}/${PROJECT_FOLDER}/${PROJECT_CSPROJ_FILE} \
    --no-restore \
    --configuration ${DOTNET_CONFIGURATION} \
    --runtime ${DOTNET_RUNTIME} \
    --self-contained true \
    --output ${BUILD_ARTIFACTS_FOLDER}/${PROJECT_FOLDER}/${DOTNET_CONFIGURATION}/${DOTNET_RUNTIME};

## Tools image
FROM $BASE_IMAGE:$ALPINE_IMAGE_TAG AS tools
ARG BUILD_ADDITIONAL_PACKAGES
USER root
# Устанавливаем дополнительные пакеты, необходимые для работы приложения
ENV TOOLS="tzdata strace curl net-tools openssl $BUILD_ADDITIONAL_PACKAGES"
RUN for TOOL in $TOOLS ; do apk add --update --no-cache $TOOL; done;

## Final image
FROM tools AS final
USER root
ARG UID=1001
ARG GID=1001
ARG APP_USER=appuser
ARG DOTNET_CONFIGURATION=Release
ARG DOTNET_RUNTIME=linux-musl-x64
ARG APPS_FOLDER=/apps
# Параметры среды для финального контейнера
ENV ENTRYPOINT="./app"
ENV DOTNET_EnableDiagnostics=0
ENV TZ="UTC"

# Настраиваем рабочую директорию и окружение
WORKDIR $APPS_FOLDER
RUN \
    ulimit -S 4096 ; \
    cp /usr/share/zoneinfo/${TZ} /etc/localtime ; \
    # Создаем группу и пользователя для запуска приложения
    addgroup --gid $GID $APP_USER && \
    adduser -s /bin/sh -D --gecos "" --ingroup "$APP_USER" --no-create-home --uid "$UID" "$APP_USER" && \
    # Устанавливаем права на директорию приложения
    chown -R $UID:$GID $APPS_FOLDER && \
    chmod -R 755 $APPS_FOLDER

# Копируем собранное приложение из предыдущего шага
COPY --from=builder --chown=$UID:$GID /build/$BUILD_ARTIFACTS_FOLDER/$PROJECT_FOLDER/$DOTNET_CONFIGURATION/$DOTNET_RUNTIME ./
# Добавляем метаданные о сборке в финальный образ
LABEL \
    base_image="${BASE_IMAGE}" \
    os="alpine:${ALPINE_IMAGE_TAG}" \
    dotnet_version="${DOTNET_VERSION}" \
    image_tools="${TOOLS}" \
    image_tz="${TZ}"

# Открываем порты для приложения (если требуется)
EXPOSE 5000
EXPOSE 5001

# Запускаем приложение от имени нового пользователя
USER $UID
ENTRYPOINT $ENTRYPOINT