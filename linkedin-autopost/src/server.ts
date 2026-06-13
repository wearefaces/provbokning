import express from "express";
import type { Request, Response, NextFunction } from "express";
import crypto from "node:crypto";
import { config, configWarnings } from "./config.js";
import { getJSON, getProfile, setJSON } from "./db.js";
import type { Profile } from "./db.js";
import {
  listDrafts,
  publishDraft,
  setDraftStatus,
  updateDraftContent,
} from "./drafts.js";
import {
  authorizeUrl,
  connectionStatus,
  disconnect,
  exchangeCode,
  isConfigured,
} from "./linkedin.js";
import { isRunning, runPipeline } from "./pipeline.js";
import { addFeed, listFeeds, removeFeed } from "./sources/rss.js";
import { addLink, deleteLink, listLinks } from "./sources/links.js";
import { logger } from "./logger.js";
import { renderDrafts, renderLogin, renderSettings, renderSources } from "./views.js";

const COOKIE = "lap_session";

function sign(value: string): string {
  return crypto.createHmac("sha256", config.sessionSecret).update(value).digest("hex");
}
const SESSION_TOKEN = sign("authenticated");

function parseCookies(req: Request): Record<string, string> {
  const header = req.headers.cookie;
  if (!header) return {};
  const out: Record<string, string> = {};
  for (const part of header.split(";")) {
    const idx = part.indexOf("=");
    if (idx === -1) continue;
    out[part.slice(0, idx).trim()] = decodeURIComponent(part.slice(idx + 1).trim());
  }
  return out;
}

function isAuthed(req: Request): boolean {
  if (!config.appPassword) return true; // open mode
  return parseCookies(req)[COOKIE] === SESSION_TOKEN;
}

function redirectMsg(res: Response, path: string, msg: string, kind: "ok" | "err" = "ok"): void {
  res.redirect(`${path}?msg=${encodeURIComponent(msg)}&kind=${kind}`);
}

export function buildServer() {
  const app = express();
  app.use(express.urlencoded({ extended: true }));
  app.use(express.json());
  app.use(express.static("public"));

  app.get("/healthz", (_req, res) => res.json({ ok: true }));

  // ---- auth ----
  app.get("/login", (req, res) => {
    if (isAuthed(req)) return res.redirect("/");
    res.send(renderLogin());
  });

  app.post("/login", (req, res) => {
    if (!config.appPassword) return res.redirect("/");
    if (req.body.password === config.appPassword) {
      res.setHeader(
        "Set-Cookie",
        `${COOKIE}=${SESSION_TOKEN}; HttpOnly; Path=/; SameSite=Lax; Max-Age=2592000`,
      );
      return res.redirect("/");
    }
    res.status(401).send(renderLogin("Wrong password."));
  });

  app.get("/logout", (_req, res) => {
    res.setHeader("Set-Cookie", `${COOKIE}=; HttpOnly; Path=/; Max-Age=0`);
    res.redirect("/login");
  });

  // gate everything below
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (isAuthed(req)) return next();
    res.redirect("/login");
  });

  // ---- drafts dashboard ----
  app.get("/", (req, res) => {
    res.send(
      renderDrafts({
        drafts: listDrafts(),
        connection: connectionStatus(),
        generating: isRunning(),
        lastRun: getJSON("last_run", null),
        flash: req.query.msg as string | undefined,
        flashKind: (req.query.kind as "ok" | "err") || "ok",
      }),
    );
  });

  app.post("/api/generate", async (_req, res) => {
    if (isRunning()) return redirectMsg(res, "/", "A run is already in progress.", "err");
    // Kick it off in the background; the dashboard shows progress on refresh.
    runPipeline()
      .then((r) => logger.info(`Manual run finished: ${r.created} drafts`))
      .catch((err) => logger.error("Manual run failed", err));
    redirectMsg(res, "/", "Generation started — refresh in a moment.");
  });

  app.post("/api/drafts/:id/save", (req, res) => {
    updateDraftContent(Number(req.params.id), req.body.content ?? "", req.body.hashtags ?? "");
    redirectMsg(res, "/", "Saved.");
  });
  app.post("/api/drafts/:id/approve", (req, res) => {
    setDraftStatus(Number(req.params.id), "approved");
    redirectMsg(res, "/", "Approved.");
  });
  app.post("/api/drafts/:id/reject", (req, res) => {
    setDraftStatus(Number(req.params.id), "rejected");
    redirectMsg(res, "/", "Rejected.");
  });
  app.post("/api/drafts/:id/publish", async (req, res) => {
    try {
      const urn = await publishDraft(Number(req.params.id));
      redirectMsg(res, "/", `Published to LinkedIn (${urn}).`);
    } catch (err) {
      redirectMsg(res, "/", err instanceof Error ? err.message : "Publish failed.", "err");
    }
  });

  // ---- sources ----
  app.get("/sources", (req, res) => {
    res.send(
      renderSources({
        feeds: listFeeds(),
        links: listLinks(),
        flash: req.query.msg as string | undefined,
        flashKind: (req.query.kind as "ok" | "err") || "ok",
      }),
    );
  });
  app.post("/api/feeds", (req, res) => {
    const url = String(req.body.url || "").trim();
    if (url) addFeed(url);
    redirectMsg(res, "/sources", url ? "Feed added." : "Missing URL.", url ? "ok" : "err");
  });
  app.post("/api/feeds/:id/delete", (req, res) => {
    removeFeed(Number(req.params.id));
    redirectMsg(res, "/sources", "Feed removed.");
  });
  app.post("/api/links", (req, res) => {
    const url = String(req.body.url || "").trim();
    if (url) addLink(url, req.body.note);
    redirectMsg(res, "/sources", url ? "Link added." : "Missing URL.", url ? "ok" : "err");
  });
  app.post("/api/links/:id/delete", (req, res) => {
    deleteLink(Number(req.params.id));
    redirectMsg(res, "/sources", "Link removed.");
  });

  // ---- settings ----
  app.get("/settings", (req, res) => {
    res.send(
      renderSettings({
        profile: getProfile(),
        connection: connectionStatus(),
        linkedinConfigured: isConfigured(),
        warnings: configWarnings(),
        cron: config.generateCron,
        flash: req.query.msg as string | undefined,
        flashKind: (req.query.kind as "ok" | "err") || "ok",
      }),
    );
  });
  app.post("/api/profile", (req, res) => {
    const profile: Profile = {
      name: String(req.body.name || "").trim(),
      headline: String(req.body.headline || "").trim(),
      about: String(req.body.about || "").trim(),
      themes: String(req.body.themes || "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
    };
    setJSON("profile", profile);
    redirectMsg(res, "/settings", "Profile saved.");
  });

  // ---- LinkedIn OAuth ----
  app.get("/auth/linkedin", (req, res) => {
    if (!isConfigured()) return redirectMsg(res, "/settings", "LinkedIn app not configured.", "err");
    const state = crypto.randomBytes(16).toString("hex");
    res.setHeader(
      "Set-Cookie",
      `li_state=${state}; HttpOnly; Path=/; SameSite=Lax; Max-Age=600`,
    );
    res.redirect(authorizeUrl(state));
  });

  app.get("/auth/linkedin/callback", async (req, res) => {
    const { code, state, error, error_description } = req.query as Record<string, string>;
    if (error) return redirectMsg(res, "/settings", `LinkedIn: ${error_description || error}`, "err");
    const expected = parseCookies(req)["li_state"];
    if (!state || state !== expected) {
      return redirectMsg(res, "/settings", "OAuth state mismatch — try again.", "err");
    }
    try {
      await exchangeCode(code);
      redirectMsg(res, "/settings", "LinkedIn connected.");
    } catch (err) {
      redirectMsg(res, "/settings", err instanceof Error ? err.message : "Connection failed.", "err");
    }
  });

  app.post("/auth/linkedin/disconnect", (_req, res) => {
    disconnect();
    redirectMsg(res, "/settings", "Disconnected.");
  });

  return app;
}
