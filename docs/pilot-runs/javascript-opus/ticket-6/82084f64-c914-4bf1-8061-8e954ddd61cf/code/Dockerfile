# Base image is pinned by project policy: Node.js 20 on Alpine.
FROM node:20-alpine AS base
WORKDIR /app
ENV NODE_ENV=production
# No runtime dependencies yet; package.json is copied for "type": "module".
COPY package.json ./
COPY src/ ./src/
# Runs as an unprivileged user by default; compose overrides the UID/GID
# so files in the bind-mounted data dir belong to the invoking host user.
USER node

FROM base AS server
ENTRYPOINT ["node", "/app/src/server-main.js"]

FROM base AS test
ENV NODE_ENV=test
COPY test/ ./test/
CMD ["node", "--test", "--test-reporter=spec"]
