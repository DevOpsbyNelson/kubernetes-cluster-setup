import { setTimeout as sleep } from 'node:timers/promises';
import { Router, type Request, type Response } from 'express';
import { withSpan } from './tracer.ts';

// Routes that produce varied telemetry for exploring Grafana: multi-step,
// slow and failing requests. Mounted only when DEMO_ROUTES=true (app.ts);
// keep it off in real deployments.
export const demoRouter: Router = Router();

const jitter = (min: number, max: number) => min + Math.floor(Math.random() * (max - min));

// Two child spans with variable latency, and an info log inside the trace.
demoRouter.get('/work', async (req: Request, res: Response) => {
  const items = await withSpan('demo.load_items', async (span) => {
    await sleep(jitter(20, 150));
    const count = jitter(1, 10);
    span.setAttribute('demo.items', count);
    return count;
  });
  await withSpan('demo.process_items', async (span) => {
    span.setAttribute('demo.items', items);
    await sleep(jitter(10, 80) * items);
  });
  req.log.info({ items }, 'demo work processed');
  res.json({ items });
});

// Slower than Alloy's 2 s threshold, so tail sampling always keeps the trace.
demoRouter.get('/slow', async (req: Request, res: Response) => {
  const ms = Math.min(Number(req.query.ms ?? 2500) || 2500, 10_000);
  await withSpan('demo.slow_dependency', async (span) => {
    span.setAttribute('demo.delay_ms', ms);
    await sleep(ms);
  });
  req.log.warn({ ms }, 'demo slow dependency responded');
  res.json({ ms });
});

// Fails inside a child span: the span records the exception and goes ERROR,
// the error handler logs it with the stack and answers 500.
demoRouter.get('/error', async () => {
  await withSpan('demo.charge_payment', async (span) => {
    span.setAttribute('demo.provider', 'acme-pay');
    await sleep(jitter(5, 40));
    throw new Error('payment provider unavailable');
  });
});
