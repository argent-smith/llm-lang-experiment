FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
COPY test ./test

RUN npm run build

EXPOSE 8080

ENTRYPOINT ["node", "dist/index.js"]
