import { randomUUID } from 'node:crypto';
import { context, trace } from '@opentelemetry/api';
import { getRPCMetadata } from '@opentelemetry/core';
import express, { type Express, type NextFunction, type Request, type Response } from 'express';
import { pinoHttp } from 'pino-http';
import { demoRouter } from './demo.ts';
import { sdk } from './instrumentation.ts';
import { logger } from './logger.ts';
import { withSyncSpan } from './tracer.ts';

const app: Express = express();
const port = Number(process.env.PORT ?? 3000);

app.use(
  pinoHttp({
    logger,
    // Reuse an upstream request ID (load balancer / gateway) or create one, and echo it back.
    genReqId: (req, res) => {
      const id = (req.headers['x-request-id'] as string | undefined) ?? randomUUID();
      res.setHeader('x-request-id', id);
      return id;
    },
    customLogLevel: (_req, res, err) => {
      if (err || res.statusCode >= 500) return 'error';
      if (res.statusCode >= 400) return 'warn';
      return 'info';
    },
    // Container healthchecks hit this every 30s; logging them is noise.
    autoLogging: { ignore: (req) => req.url === '/health/ping' },
  }),
);

// Span enrichment: ties the request span to the request ID found in the logs,
// and hands the trace ID to the client so a bug report can name the exact
// trace. Add business attributes (user ID, tenant…) here once auth exists.
// Set on the root HTTP server span (kept by the http instrumentation in the
// request's RPC metadata), which is the one searched in Tempo, rather than on
// whichever express span happens to be active here.
app.use((req: Request, res: Response, next: NextFunction) => {
  const span = getRPCMetadata(context.active())?.span ?? trace.getActiveSpan();
  if (span) {
    span.setAttribute('http.request.id', String(req.id));
    res.setHeader('x-trace-id', span.spanContext().traceId);
  }
  next();
});

app.get('/health/ping', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/', (req: Request, res: Response) => {
  req.log.debug('handling root request');
  const greeting = withSyncSpan('greeting.build', (span) => {
    span.setAttribute('greeting.locale', 'en');
    return 'Hello World!';
  });
  res.send(greeting);
});

if (process.env.DEMO_ROUTES === 'true') {
  app.use('/demo', demoRouter);
}

app.use((err: Error, req: Request, res: Response, _next: NextFunction) => {
  req.log.error({ err }, 'unhandled request error');
  const traceId = trace.getActiveSpan()?.spanContext().traceId;
  res.status(500).json({ error: 'Internal Server Error', requestId: req.id, traceId });
});

const server = app.listen(port, () => {
  logger.info({ port }, 'server listening');
});

const shutdown = (signal: string) => {
  logger.info({ signal }, 'shutting down');
  server.close(async () => {
    logger.info('server closed');
    // Flush spans and log records still buffered in the batch processors.
    await sdk.shutdown().catch((err) => logger.error({ err }, 'telemetry shutdown failed'));
    process.exit(0);
  });
  setTimeout(() => {
    logger.error('forced shutdown after timeout');
    process.exit(1);
  }, 10_000).unref();
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

process.on('unhandledRejection', (reason) => {
  logger.fatal({ err: reason }, 'unhandled promise rejection');
  process.exit(1);
});

process.on('uncaughtException', (err) => {
  logger.fatal({ err }, 'uncaught exception');
  process.exit(1);
});
