FROM node:20-alpine

WORKDIR /app

COPY package.json ./
COPY src ./src
COPY test ./test

ENTRYPOINT ["node", "src/index.js"]
