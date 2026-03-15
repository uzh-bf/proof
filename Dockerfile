# ── Stage 1: install dependencies ────────────────────────────────────
FROM node:22-bookworm-slim AS deps

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy workspace package manifests first for layer caching
COPY package.json package-lock.json ./
COPY packages/agent-bridge/package.json   packages/agent-bridge/
COPY packages/doc-core/package.json       packages/doc-core/
COPY packages/doc-editor/package.json     packages/doc-editor/
COPY packages/doc-server/package.json     packages/doc-server/
COPY packages/doc-store-sqlite/package.json packages/doc-store-sqlite/
COPY apps/proof-example/package.json      apps/proof-example/

RUN npm ci

# ── Stage 2: build frontend ─────────────────────────────────────────
FROM deps AS build

ARG COMMIT_SHA
ARG BUILD_DATE

COPY . .

RUN npm run build

# Generate build metadata
RUN echo "{\"sha\":\"${COMMIT_SHA}\",\"generatedAt\":\"${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}\"}" \
    > .proof-build-info.json

# ── Stage 3: production image ───────────────────────────────────────
FROM node:22-bookworm-slim AS production

RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy workspace package manifests for production install
COPY package.json package-lock.json ./
COPY packages/agent-bridge/package.json   packages/agent-bridge/
COPY packages/doc-core/package.json       packages/doc-core/
COPY packages/doc-editor/package.json     packages/doc-editor/
COPY packages/doc-server/package.json     packages/doc-server/
COPY packages/doc-store-sqlite/package.json packages/doc-store-sqlite/
COPY apps/proof-example/package.json      apps/proof-example/

# Install prod deps, rebuild native modules, then remove build toolchain in one layer
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && npm ci --omit=dev && npm rebuild better-sqlite3 @resvg/resvg-js \
    && apt-get purge -y python3 make g++ && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# tsx is a devDependency but required at runtime (server imports raw TS from src/)
COPY --from=deps /app/node_modules/tsx          node_modules/tsx
COPY --from=deps /app/node_modules/esbuild      node_modules/esbuild
COPY --from=deps /app/node_modules/@esbuild     node_modules/@esbuild
COPY --from=deps /app/node_modules/get-tsconfig    node_modules/get-tsconfig
COPY --from=deps /app/node_modules/resolve-pkg-maps node_modules/resolve-pkg-maps

# Copy application source
COPY server/          server/
COPY src/             src/
COPY packages/        packages/
COPY public/          public/
COPY docs/agent-docs.md docs/agent-docs.md
COPY tsconfig.json tsconfig.server.json vite.config.ts ./

# Copy built frontend assets
COPY --from=build /app/dist/          dist/
COPY --from=build /app/.proof-build-info.json .

# Create non-root user and data directories
RUN groupadd -g 1001 proof && useradd -u 1001 -g proof -m proof \
    && mkdir -p /data/db /data/snapshots \
    && chown -R proof:proof /data /app

USER proof

ENV NODE_ENV=production
EXPOSE 4000

ENTRYPOINT ["tini", "--"]
CMD ["node", "--import", "tsx", "server/index.ts"]
