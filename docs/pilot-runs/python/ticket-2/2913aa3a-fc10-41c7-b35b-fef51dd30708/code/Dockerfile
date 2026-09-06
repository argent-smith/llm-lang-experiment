FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY syncbox_server ./syncbox_server
COPY tests ./tests

ENV PYTHONUNBUFFERED=1

CMD ["python", "-m", "syncbox_server.main"]
