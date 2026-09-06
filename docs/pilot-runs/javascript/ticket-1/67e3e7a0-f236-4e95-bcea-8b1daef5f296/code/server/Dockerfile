FROM node:20-alpine

WORKDIR /app

COPY package.json ./
COPY src ./src

ENTRYPOINT ["node", "src/index.js"]
