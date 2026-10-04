# syntax=docker/dockerfile:1

# --- dependencies (incl. dev: TypeScript, type definitions) ---------------
FROM node:20-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# --- compile server sources -----------------------------------------------
FROM deps AS build
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

# --- test image: compiled sources + compiled tests ------------------------
FROM build AS test
COPY test ./test
RUN npm run build:test
CMD ["npm", "test", "--silent"]

# --- runtime image: production dependencies and compiled server only ------
FROM node:20-bookworm-slim AS server
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY --from=build /app/dist/src ./dist/src
USER node
EXPOSE 8080
CMD ["node", "dist/src/main.js"]
