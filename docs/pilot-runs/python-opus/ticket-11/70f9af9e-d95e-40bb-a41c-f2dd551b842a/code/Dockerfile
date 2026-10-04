FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app
COPY syncbox ./syncbox


FROM base AS runtime

ENTRYPOINT ["python", "-m", "syncbox.server"]


FROM base AS client

COPY --chmod=755 bin/syncbox /usr/local/bin/syncbox

ENTRYPOINT ["syncbox"]


FROM client AS test

COPY requirements-dev.txt ./
RUN pip install --no-cache-dir --root-user-action=ignore -r requirements-dev.txt
COPY pyproject.toml ./
COPY tests ./tests

ENTRYPOINT ["python", "-m", "pytest"]
