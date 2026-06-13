import Parser from "rss-parser";
import { db } from "../db.js";
import type { Feed } from "../db.js";
import { logger } from "../logger.js";

const parser = new Parser({ timeout: 15000 });

export interface FeedItem {
  feedTitle: string;
  guid: string;
  title: string;
  url: string;
  snippet: string;
  isoDate?: string;
}

const seenStmt = db.prepare("SELECT 1 FROM seen_items WHERE guid = ?");
const markSeenStmt = db.prepare(
  "INSERT OR IGNORE INTO seen_items (guid, url, title) VALUES (?, ?, ?)",
);

export function listFeeds(): Feed[] {
  return db.prepare("SELECT * FROM feeds ORDER BY created_at DESC").all() as Feed[];
}

export function addFeed(url: string): void {
  db.prepare("INSERT OR IGNORE INTO feeds (url) VALUES (?)").run(url.trim());
}

export function removeFeed(id: number): void {
  db.prepare("DELETE FROM feeds WHERE id = ?").run(id);
}

function isSeen(guid: string): boolean {
  return Boolean(seenStmt.get(guid));
}

export function markSeen(item: FeedItem): void {
  markSeenStmt.run(item.guid, item.url, item.title);
}

/**
 * Fetch all configured feeds and return fresh items we haven't processed yet,
 * newest first. Failures on individual feeds are logged and skipped.
 */
export async function fetchFreshItems(maxPerFeed = 5): Promise<FeedItem[]> {
  const feeds = listFeeds();
  const fresh: FeedItem[] = [];

  for (const feed of feeds) {
    try {
      const parsed = await parser.parseURL(feed.url);
      const feedTitle = parsed.title || feed.title || feed.url;
      if (!feed.title && parsed.title) {
        db.prepare("UPDATE feeds SET title = ? WHERE id = ?").run(parsed.title, feed.id);
      }
      let count = 0;
      for (const entry of parsed.items) {
        if (count >= maxPerFeed) break;
        const guid = entry.guid || entry.link || entry.title || "";
        if (!guid || isSeen(guid)) continue;
        fresh.push({
          feedTitle,
          guid,
          title: entry.title || "(untitled)",
          url: entry.link || "",
          snippet: (entry.contentSnippet || entry.content || entry.summary || "").trim(),
          isoDate: entry.isoDate,
        });
        count++;
      }
    } catch (err) {
      logger.warn(`Failed to fetch feed ${feed.url}`, err);
    }
  }

  // Newest first when dates are available.
  fresh.sort((a, b) => (b.isoDate || "").localeCompare(a.isoDate || ""));
  return fresh;
}
