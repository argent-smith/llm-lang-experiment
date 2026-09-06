FROM node:20-alpine

WORKDIR /app

COPY package.json ./
COPY bin ./bin
COPY src ./src
COPY support ./support
COPY test ./test

ENTRYPOINT ["node", "bin/syncbox"]
