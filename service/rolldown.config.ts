import { defineConfig } from 'rolldown';

// Minifies src/ with Oxc (via Rolldown). Dependencies stay external and are
// loaded from node_modules at runtime: OpenTelemetry patches express, pino and
// http as they are imported, which it cannot do to code bundled into our file.
// instrumentation.mjs is its own entry so it can be preloaded with --import.
export default defineConfig({
  input: {
    app: 'src/app.ts',
    instrumentation: 'src/instrumentation.ts',
  },
  platform: 'node',
  // Package names and node: builtins. Resolved paths are tested too, so the
  // pattern must not match absolute ones like C:\... or /app/...
  external: /^(node:|@?[a-z0-9][\w.-]*(\/|$))/,
  output: {
    dir: 'dist',
    format: 'esm',
    entryFileNames: '[name].mjs',
    minify: true,
    sourcemap: true,
  },
});
