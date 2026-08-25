FROM python:3.12-slim AS base

WORKDIR /app

COPY server/requirements.txt server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt

COPY server server

ENTRYPOINT ["python", "-m", "server.main"]


FROM base AS test

COPY server/requirements-dev.txt server/requirements-dev.txt
RUN pip install --no-cache-dir -r server/requirements-dev.txt

ENTRYPOINT ["python", "-m", "pytest"]
CMD ["server/tests"]
