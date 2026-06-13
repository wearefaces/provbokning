import * as cheerio from "cheerio";
import { db } from "../db.js";
import type { SavedLink } from "../db.js";

export function listLinks(status?: SavedLink["status"]): SavedLink[] {
  if (status) {
    return db
      .prepare("SELECT * FROM links WHERE status = ? ORDER BY created_at DESC")
      .all(status) as SavedLink[];
  }
  return db.prepare("SELECT * FROM links ORDER BY created_at DESC").all() as SavedLink[];
}

export function addLink(url: string, note?: string): void {
  db.prepare("INSERT INTO links (url, note) VALUES (?, ?)").run(url.trim(), note?.trim() || null);
}

export function setLinkStatus(id: number, status: SavedLink["status"], error?: string): void {
  db.prepare("UPDATE links SET status = ?, error = ? WHERE id = ?").run(status, error || null, id);
}

export function deleteLink(id: number): void {
  db.prepare("DELETE FROM links WHERE id = ?").run(id);
}

export interface FetchedArticle {
  title: string;
  text: string;
}

/** Fetch a URL and extract readable title + body text (best effort). */
export async function fetchArticle(url: string): Promise<FetchedArticle> {
  const res = await fetch(url, {
    headers: {
      "User-Agent":
        "Mozilla/5.0 (compatible; linkedin-autopost/0.1; +https://github.com/wearefaces/linkedin-autopost)",
      Accept: "text/html,application/xhtml+xml",
    },
    redirect: "follow",
  });
  if (!res.ok) throw new Error(`Fetch failed (${res.status}) for ${url}`);

  const html = await res.text();
  const $ = cheerio.load(html);

  $("script, style, nav, header, footer, noscript, iframe, svg").remove();

  const title =
    $('meta[property="og:title"]').attr("content") ||
    $("title").first().text() ||
    url;

  // Prefer <article>, fall back to <main>, then body.
  const container = $("article").length ? $("article") : $("main").length ? $("main") : $("body");
  const text = container
    .find("p, li, h1, h2, h3")
    .map((_, el) => $(el).text().trim())
    .get()
    .filter((t) => t.length > 0)
    .join("\n");

  return { title: title.trim(), text: text.trim() || $("body").text().trim() };
}
