FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY syncbox ./syncbox

ENTRYPOINT ["python", "-m", "syncbox.server"]


FROM runtime AS test

COPY requirements-dev.txt ./
RUN pip install --no-cache-dir --root-user-action=ignore -r requirements-dev.txt
COPY pyproject.toml ./
COPY tests ./tests

ENTRYPOINT ["python", "-m", "pytest"]
