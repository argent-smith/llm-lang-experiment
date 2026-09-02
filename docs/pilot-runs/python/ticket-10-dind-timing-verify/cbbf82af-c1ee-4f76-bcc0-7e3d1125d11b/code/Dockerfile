FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server ./server
COPY client ./client
COPY syncbox ./syncbox
COPY tests ./tests

RUN chmod +x ./syncbox

CMD ["python", "-m", "server"]
