import Database from "better-sqlite3";
import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const DB_PATH = process.env.DB_PATH?.trim() || "data/app.sqlite";

if (!existsSync(dirname(DB_PATH))) mkdirSync(dirname(DB_PATH), { recursive: true });

export const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

db.exec(`
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS feeds (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  url        TEXT NOT NULL UNIQUE,
  title      TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Tracks RSS items we've already turned into (or considered for) drafts, so we
-- don't keep re-drafting the same article.
CREATE TABLE IF NOT EXISTS seen_items (
  guid    TEXT PRIMARY KEY,
  url     TEXT,
  title   TEXT,
  seen_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Links the user pastes in for the bot to draft from.
CREATE TABLE IF NOT EXISTS links (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  url        TEXT NOT NULL,
  note       TEXT,
  status     TEXT NOT NULL DEFAULT 'pending', -- pending | used | error
  error      TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS drafts (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  source_type  TEXT NOT NULL,                 -- rss | link | idea
  source_ref   TEXT,                          -- url / idea text it came from
  title        TEXT,                          -- short internal label
  content      TEXT NOT NULL,                 -- the post body (what gets published)
  hashtags     TEXT,                          -- space-separated #tags
  status       TEXT NOT NULL DEFAULT 'draft', -- draft | approved | published | rejected
  li_post_urn  TEXT,                          -- LinkedIn post URN once published
  error        TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
  published_at TEXT
);
`);

// ---------------- settings helpers ----------------

const getSettingStmt = db.prepare("SELECT value FROM settings WHERE key = ?");
const setSettingStmt = db.prepare(
  "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
);

export function getSetting(key: string): string | null {
  const row = getSettingStmt.get(key) as { value: string } | undefined;
  return row?.value ?? null;
}

export function setSetting(key: string, value: string): void {
  setSettingStmt.run(key, value);
}

export function getJSON<T>(key: string, fallback: T): T {
  const raw = getSetting(key);
  if (!raw) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export function setJSON(key: string, value: unknown): void {
  setSetting(key, JSON.stringify(value));
}

// ---------------- types ----------------

export interface Draft {
  id: number;
  source_type: string;
  source_ref: string | null;
  title: string | null;
  content: string;
  hashtags: string | null;
  status: "draft" | "approved" | "published" | "rejected";
  li_post_urn: string | null;
  error: string | null;
  created_at: string;
  updated_at: string;
  published_at: string | null;
}

export interface Feed {
  id: number;
  url: string;
  title: string | null;
  created_at: string;
}

export interface SavedLink {
  id: number;
  url: string;
  note: string | null;
  status: "pending" | "used" | "error";
  error: string | null;
  created_at: string;
}

// ---------------- profile (used to steer generation) ----------------

export interface Profile {
  name: string;
  headline: string;
  // Free text describing who you are, your audience, topics you post about, and tone.
  about: string;
  themes: string[];
}

export const DEFAULT_PROFILE: Profile = {
  name: "",
  headline: "",
  about: "",
  themes: [],
};

export function getProfile(): Profile {
  return getJSON<Profile>("profile", DEFAULT_PROFILE);
}
