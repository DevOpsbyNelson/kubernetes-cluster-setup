# syntax=docker/dockerfile:1.7
#
# Multi-stage production build.
#
# Stages:
#   build      - full (dev+prod) install from the lockfile, then `pnpm build`:
#                Rolldown minifies src/ with Oxc into dist/ (see rolldown.config.ts)
#   prod-deps  - production-only install (no devDependencies)
#   runtime    - final image: prod node_modules + dist/, non-root, tini as PID 1
#
# node_modules ships because dependencies are not bundled: OpenTelemetry patches
# express, pino and http as they are imported, which needs real packages.
# Type checking belongs in CI (`pnpm typecheck`); Rolldown only strips types.

FROM node:26.12.1-slim AS build
WORKDIR /app

RUN npm install -g pnpm@12.4.1

# Manifest + lockfile first so the install layer stays cached until
# dependencies actually change. pnpm-workspace.yaml holds the build-script
# approvals (allowBuilds) that a frozen install requires.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

COPY tsconfig.json rolldown.config.ts ./
COPY src ./src
RUN pnpm build

# ---------------------------------------------------------------------------

FROM node:26.12.1-slim AS prod-deps
WORKDIR /app

RUN npm install -g pnpm@12.4.1

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --prod --frozen-lockfile

# ---------------------------------------------------------------------------

FROM node:26.12.1-slim AS runtime
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000

# tini becomes PID 1: reaps zombies and forwards SIGTERM/SIGINT to node so the
# graceful shutdown in app.ts runs (and flushes telemetry) instead of Docker
# force-killing the process after its stop timeout. Unpinned on purpose: Debian
# rebuilds bump the +bN revision and drop the old one from the index, which
# breaks an exact pin.
RUN apt-get update \
  && apt-get install -y --no-install-recommends tini \
  && rm -rf /var/lib/apt/lists/*

# The source maps keep stack traces in the logs pointing at src/ instead of
# minified code. node:*-slim ships a non-root `node` user (uid/gid 1000).
COPY --chown=node:node --from=prod-deps /app/node_modules ./node_modules
COPY --chown=node:node --from=build /app/dist ./dist
COPY --chown=node:node package.json ./

USER node

# 3000: app. 9464: Prometheus /metrics (OpenTelemetry exporter), scraped over
# the private network only - do not publish it.
EXPOSE 3000 9464

# Liveness only - /health/ping has no dependencies, so an outage elsewhere
# (Alloy, Tempo, Loki) does not mark this container unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health/ping').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["tini", "--"]
# Exec form: node is tini's direct child and receives signals itself.
# --import loads OpenTelemetry before the app so its imports get patched.
CMD ["node", "--enable-source-maps", "--import", "./dist/instrumentation.mjs", "dist/app.mjs"]
