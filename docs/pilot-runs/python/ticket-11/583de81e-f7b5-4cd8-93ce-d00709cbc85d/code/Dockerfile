FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY syncbox_server ./syncbox_server
COPY syncbox_client ./syncbox_client
COPY tests ./tests
COPY bin/syncbox /usr/local/bin/syncbox
RUN chmod +x /usr/local/bin/syncbox

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app

CMD ["python", "-m", "syncbox_server.main"]
