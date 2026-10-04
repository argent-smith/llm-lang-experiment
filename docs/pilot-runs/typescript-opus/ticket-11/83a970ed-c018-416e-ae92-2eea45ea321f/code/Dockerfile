# syntax=docker/dockerfile:1

# --- dependencies (incl. dev: TypeScript, type definitions) ---------------
FROM node:20-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# --- compile server and client sources ------------------------------------
FROM deps AS build
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

# --- test image: compiled sources + compiled tests ------------------------
FROM build AS test
COPY bin ./bin
COPY test ./test
RUN npm run build:test
# Not root, like the client in use: otherwise file permissions don't apply
# and failures to read local files can't be tested.
USER node
CMD ["npm", "test", "--silent"]

# --- runtime base: production dependencies and compiled sources only ------
FROM node:20-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY --from=build /app/dist/src ./dist/src

# --- server image ---------------------------------------------------------
FROM runtime AS server
USER node
EXPOSE 8080
CMD ["node", "dist/src/main.js"]

# --- client image: the `syncbox` CLI --------------------------------------
FROM runtime AS client
COPY bin/syncbox ./bin/syncbox
# /state: mount point of the sync state volume. The client runs as the
# invoking host user, whose uid isn't known here: the volume takes over this
# directory's mode when Docker creates it, so it is writable by anyone (and
# sticky, so one user can't remove another's files).
RUN ln -s /app/bin/syncbox /usr/local/bin/syncbox && mkdir -m 1777 /state
USER node
ENTRYPOINT ["syncbox"]
