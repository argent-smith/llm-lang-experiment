# shellcheck shell=bash
# Общее для run-server и run-client. Не исполняемый сам по себе —
# подключается через `source`.

IMAGE="syncbox-reference-impl"
IMPL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_image() {
  # --quiet печатает только image id — уводим в stderr, чтобы не мешать
  # стандартному выводу сервера/клиента. Пересборка почти бесплатна
  # благодаря слойному кешу Docker, когда Dockerfile не менялся.
  docker build --quiet -t "$IMAGE" "$IMPL_DIR" >&2
}

container_name_for_port() {
  echo "syncbox-reference-server-$1"
}
