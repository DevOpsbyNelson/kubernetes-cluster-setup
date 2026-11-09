import type { IncomingMessage } from 'node:http';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { PrometheusExporter } from '@opentelemetry/exporter-prometheus';
import { HostMetrics } from '@opentelemetry/host-metrics';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { ExpressLayerType } from '@opentelemetry/instrumentation-express';
import { BatchLogRecordProcessor } from '@opentelemetry/sdk-logs';
import { NodeSDK } from '@opentelemetry/sdk-node';
import { register } from 'import-in-the-middle/register-hooks.mjs';

// Must be preloaded with `node --import` so it runs before the app imports
// express, pino and http; otherwise they load unpatched.
//
// Signals:
//   metrics - pulled by Prometheus from GET :9464/metrics, a separate port so
//             metrics are never exposed through the public app port
//   traces  - pushed over OTLP/HTTP to OTEL_EXPORTER_OTLP_ENDPOINT
//   logs    - pino records bridged to OTLP by the pino instrumentation, same endpoint

// ESM loader hook that lets the instrumentations patch `import`ed modules,
// installed in-thread with module.registerHooks() instead of the deprecated
// module.register() (needs Node >= 24.11.1 / 26). Must be the same
// import-in-the-middle version @opentelemetry/instrumentation depends on: the
// hook registry is shared module state, so keep the two in step on upgrades.
register();

// Scrapes and healthchecks would otherwise produce a span every few seconds.
const ignoredPaths = new Set(['/metrics', '/health/ping']);

export const sdk = new NodeSDK({
  serviceName: process.env.SERVICE_NAME ?? 'service',
  traceExporter: new OTLPTraceExporter(),
  // Starts its own HTTP server on :9464/metrics. The exporter defaults to
  // localhost, which Prometheus in another container cannot reach.
  metricReaders: [new PrometheusExporter({ host: '0.0.0.0', port: 9464 })],
  logRecordProcessors: [new BatchLogRecordProcessor({ exporter: new OTLPLogExporter() })],
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-http': {
        ignoreIncomingRequestHook: (req: IncomingMessage) => ignoredPaths.has(req.url ?? ''),
      },
      // One span per middleware (pino-http, query parser…) only says it ran;
      // keep the route handler spans, which carry the timing that matters.
      '@opentelemetry/instrumentation-express': {
        ignoreLayersType: [ExpressLayerType.MIDDLEWARE],
      },
      // Express 5 runs on the standalone `router` package; instrumenting it as
      // well traces every layer twice (duplicate handler + middleware spans).
      '@opentelemetry/instrumentation-router': { enabled: false },
      // Low-value, high-volume spans.
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-dns': { enabled: false },
      '@opentelemetry/instrumentation-net': { enabled: false },
    }),
  ],
});

sdk.start();

// Process CPU and memory (process_cpu_time_*, process_memory_usage_*); the
// runtime instrumentation only covers the event loop, V8 heap and GC.
// system.* groups are left out: in a container they report the whole host.
new HostMetrics({ metricGroups: ['process.cpu', 'process.memory'] }).start();
