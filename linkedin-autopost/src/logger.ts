// Tiny structured logger. Keeps output greppable without pulling in a dependency.
type Level = "info" | "warn" | "error";

function log(level: Level, msg: string, extra?: unknown) {
  const ts = new Date().toISOString();
  const line = `${ts} [${level.toUpperCase()}] ${msg}`;
  if (extra !== undefined) {
    // Errors don't serialize well with JSON.stringify; pull out the message.
    const detail = extra instanceof Error ? extra.stack ?? extra.message : extra;
    console[level === "info" ? "log" : level](line, detail);
  } else {
    console[level === "info" ? "log" : level](line);
  }
}

export const logger = {
  info: (msg: string, extra?: unknown) => log("info", msg, extra),
  warn: (msg: string, extra?: unknown) => log("warn", msg, extra),
  error: (msg: string, extra?: unknown) => log("error", msg, extra),
};
