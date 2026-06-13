import "dotenv/config";

function str(name: string, fallback = ""): string {
  return process.env[name]?.trim() || fallback;
}

function int(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) ? n : fallback;
}

const port = int("PORT", 3000);

export const config = {
  port,
  baseUrl: str("BASE_URL", `http://localhost:${port}`).replace(/\/$/, ""),
  appPassword: str("APP_PASSWORD"),
  sessionSecret: str("SESSION_SECRET", "change-me-to-a-long-random-string"),

  anthropicApiKey: str("ANTHROPIC_API_KEY"),
  claudeModel: str("CLAUDE_MODEL", "claude-opus-4-8"),

  linkedin: {
    clientId: str("LINKEDIN_CLIENT_ID"),
    clientSecret: str("LINKEDIN_CLIENT_SECRET"),
    scopes: str("LINKEDIN_SCOPES", "openid profile w_member_social"),
    apiVersion: str("LINKEDIN_API_VERSION", "202405"),
  },

  generateCron: str("GENERATE_CRON", "0 8 * * *"),
  maxDraftsPerRun: int("MAX_DRAFTS_PER_RUN", 3),
  llmIdeasPerRun: int("LLM_IDEAS_PER_RUN", 4),
};

export const linkedinRedirectUri = `${config.baseUrl}/auth/linkedin/callback`;

export function configWarnings(): string[] {
  const w: string[] = [];
  if (!config.anthropicApiKey) w.push("ANTHROPIC_API_KEY is not set — draft generation will fail.");
  if (!config.linkedin.clientId || !config.linkedin.clientSecret)
    w.push("LINKEDIN_CLIENT_ID / LINKEDIN_CLIENT_SECRET not set — you can't connect LinkedIn yet.");
  if (!config.appPassword)
    w.push("APP_PASSWORD is not set — the web UI is open to anyone who can reach it.");
  return w;
}
