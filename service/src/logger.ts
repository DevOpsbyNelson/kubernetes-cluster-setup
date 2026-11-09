import { pino, type LoggerOptions } from 'pino';

const isProduction = process.env.NODE_ENV === 'production';

const options: LoggerOptions = {
  level: isProduction ? 'info' : 'debug',
  base: {
    service: process.env.SERVICE_NAME ?? 'service',
    env: process.env.NODE_ENV ?? 'development',
    version: process.env.npm_package_version,
  },
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: {
    // Emit "level":"info" instead of "level":30 so log backends can index it directly.
    level: (label) => ({ level: label }),
  },
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'res.headers["set-cookie"]',
      '*.password',
      '*.token',
      '*.secret',
    ],
    censor: '[REDACTED]',
  },
};

// JSON to stdout in production; human-readable output locally.
export const logger = isProduction
  ? pino(options)
  : pino({ ...options, transport: { target: 'pino-pretty', options: { colorize: true } } });
