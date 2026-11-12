# Service

A small Express 5 API in TypeScript, set up with structured logs, traces and metrics through OpenTelemetry. It's the application this repository packages and publishes to Amazon ECR.

## Requirements

- Node.js 26
- pnpm 12
- Docker, to build or run the image

## Run it locally

From this folder:

```bash
pnpm install
pnpm dev
```

The app listens on <http://localhost:3000>. Without an OpenTelemetry collector running, it still works but logs connection errors when it tries to send telemetry.

| Command | What it does |
|---|---|
| `pnpm dev` | Runs `src/` directly and restarts on file changes |
| `pnpm start` | Runs `src/` directly, without restarting |
| `pnpm typecheck` | Checks types with `tsc` |
| `pnpm build` | Minifies `src/` into `dist/` with Rolldown |

`pnpm test` is still the npm placeholder: the service has no automated tests yet.

## Endpoints

| Endpoint | Port | Returns |
|---|---|---|
| `GET /` | 3000 | `Hello World!` |
| `GET /health/ping` | 3000 | `{"status":"ok"}`. It has no dependencies, so use it for liveness checks. |
| `GET /metrics` | 9464 | Prometheus metrics. Keep this port private. |

With `DEMO_ROUTES=true`, these routes produce varied telemetry for exploring dashboards. Keep them off in real deployments.

| Endpoint | Behavior |
|---|---|
| `GET /demo/work` | Runs two steps with random delays and returns the item count |
| `GET /demo/slow?ms=2500` | Waits for `ms` milliseconds, up to 10000 |
| `GET /demo/error` | Fails on purpose and returns a 500 |

## Configuration

| Environment variable | Default | Purpose |
|---|---|---|
| `PORT` | `3000` | Port the app listens on |
| `SERVICE_NAME` | `service` | Service name in logs and telemetry |
| `NODE_ENV` | Unset locally, `production` in the image | `production` gives JSON logs at `info` level. Anything else gives readable logs at `debug` level. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | Collector that receives traces and logs |
| `DEMO_ROUTES` | Off | Set to `true` to enable the `/demo` routes |

Set `OTEL_EXPORTER_OTLP_ENDPOINT` wherever you deploy the image, otherwise traces and logs are lost.

## Observability

- **Logs:** written to stdout with `pino`, and also sent to the collector. Authorization headers, cookies and fields named `password`, `token` or `secret` are redacted.
- **Traces:** requests are traced automatically. For steps inside a request, wrap the code in `withSpan` or `withSyncSpan` from `src/tracer.ts`:

  ```ts
  const items = await withSpan('orders.load', async (span) => {
    span.setAttribute('orders.customer', customerId);
    return loadOrders(customerId);
  });
  ```

- **Metrics:** Prometheus scrapes port 9464.
- **Request IDs:** each response has an `x-request-id` header, reusing the one sent by the caller if there is one, and an `x-trace-id` header. Quote these to find a request in the logs or traces.

`src/instrumentation.ts` has to load before the app so it can patch `express`, `pino` and `http`. The `dev` and `start` scripts and the Docker image all preload it with `--import`.

## Docker

From this folder:

```bash
docker build -t service .
docker run --rm -p 127.0.0.1:3000:3000 -p 127.0.0.1:9464:9464 service
```

The image runs as the non-root `node` user, with `tini` as PID 1. On `SIGTERM` or `SIGINT`, the app stops taking requests and flushes its telemetry before exiting, or exits after 10 seconds.

Dependencies are deliberately not bundled, because OpenTelemetry can only patch real packages loaded from `node_modules`.

## Publishing

[Publish and Deploy](../.github/workflows/publish_and_deploy.yml) builds this folder and pushes it to private ECR as `eks-cluster/service`. The tag is the Git tree hash of `service/` (`git rev-parse HEAD:service`), so the image is only rebuilt when something in this folder changes.

It runs on pushes to `dev`, `staging` or `main`, then deploys the image to that branch's EKS cluster with the manifests in [`cluster/`](../cluster/). There it runs in the `service` namespace and sends telemetry to Alloy. See the [root README](../README.md#github-actions) for how branches map to environments.

## Source layout

| File | Purpose |
|---|---|
| `src/app.ts` | Express app, routes, error handling and shutdown |
| `src/instrumentation.ts` | OpenTelemetry setup, preloaded before the app |
| `src/logger.ts` | Logger settings and redaction |
| `src/tracer.ts` | `withSpan` and `withSyncSpan` helpers |
| `src/demo.ts` | Optional `/demo` routes |
