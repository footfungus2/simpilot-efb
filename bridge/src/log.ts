type Level = 'debug' | 'info' | 'warn' | 'error';

export interface LogEntry {
  time: string;
  level: Level;
  scope: string;
  message: string;
}

const verbose = process.env.SIMPILOT_DEBUG === '1';
const entries: LogEntry[] = [];

/** Keep diagnostics useful without retaining signed URLs, credentials or account paths. */
function redact(value: string): string {
  return value
    .replace(/\b(?:https?|wss?|coui):\/\/[^\s<>"']+/gi, (raw) => {
      try {
        const url = new URL(raw);
        url.username = '';
        url.password = '';
        url.search = '';
        url.hash = '';
        return url.toString();
      } catch {
        return '[URL omitted]';
      }
    })
    .replace(/\b(authorization\s*[:=]\s*)(?:bearer|basic)\s+\S+/gi, '$1[redacted]')
    .replace(/\b(token|access[_-]?token|refresh[_-]?token|api[_-]?key|password|username|userid|pilot[_ ]?id|callsign|authorization)(["']?)\s*([:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)/gi, '$1$2$3[redacted]')
    .replace(/(?:[A-Z]:\\+Users\\+|\/Users\/|\/home\/)[^,;\r\n]+/gi, '~')
    .replace(/[\r\n\x00-\x1f\x7f]/g, ' ')
    .slice(0, 2000);
}

export function logEntries(): LogEntry[] {
  return entries.map((entry) => ({ ...entry }));
}

function emit(level: Level, scope: string, msg: string, extra?: unknown): void {
  if (level === 'debug' && !verbose) return;
  const time = new Date().toISOString();
  const detail = extra instanceof Error ? extra.message : typeof extra === 'string' ? extra : '';
  const message = redact(detail ? `${msg}: ${detail}` : msg);
  entries.push({ time, level, scope, message });
  if (entries.length > 200) entries.shift();
  const line = `${time.slice(11, 23)} ${level.toUpperCase().padEnd(5)} [${scope}] ${message}`;
  const out = level === 'error' || level === 'warn' ? console.error : console.log;
  out(line);
}

export function logger(scope: string) {
  return {
    debug: (msg: string, extra?: unknown) => emit('debug', scope, msg, extra),
    info: (msg: string, extra?: unknown) => emit('info', scope, msg, extra),
    warn: (msg: string, extra?: unknown) => emit('warn', scope, msg, extra),
    error: (msg: string, extra?: unknown) => emit('error', scope, msg, extra),
  };
}
