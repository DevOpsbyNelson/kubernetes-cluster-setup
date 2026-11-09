import { SpanStatusCode, trace, type Attributes, type Span } from '@opentelemetry/api';

// Manual spans for flows auto-instrumentation can't see (business steps inside
// one request). The span is active while fn runs, so spans created inside it
// (HTTP calls, nested withSpan) become its children. Errors are recorded on
// the span, mark it ERROR (which Alloy's tail sampling always keeps), and are
// rethrown unchanged.
const tracer = trace.getTracer(process.env.SERVICE_NAME ?? 'service');

const fail = (span: Span, err: unknown) => {
  const error = err instanceof Error ? err : new Error(String(err));
  span.recordException(error);
  span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
};

export function withSpan<T>(name: string, fn: (span: Span) => Promise<T>, attributes?: Attributes): Promise<T> {
  return tracer.startActiveSpan(name, { attributes }, async (span) => {
    try {
      return await fn(span);
    } catch (err) {
      fail(span, err);
      throw err;
    } finally {
      span.end();
    }
  });
}

export function withSyncSpan<T>(name: string, fn: (span: Span) => T, attributes?: Attributes): T {
  return tracer.startActiveSpan(name, { attributes }, (span) => {
    try {
      return fn(span);
    } catch (err) {
      fail(span, err);
      throw err;
    } finally {
      span.end();
    }
  });
}
