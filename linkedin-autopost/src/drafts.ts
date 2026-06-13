import { db } from "./db.js";
import type { Draft } from "./db.js";
import { publishPost } from "./linkedin.js";

export function listDrafts(status?: Draft["status"]): Draft[] {
  if (status) {
    return db
      .prepare("SELECT * FROM drafts WHERE status = ? ORDER BY created_at DESC")
      .all(status) as Draft[];
  }
  return db.prepare("SELECT * FROM drafts ORDER BY created_at DESC").all() as Draft[];
}

export function getDraft(id: number): Draft | undefined {
  return db.prepare("SELECT * FROM drafts WHERE id = ?").get(id) as Draft | undefined;
}

export interface NewDraft {
  source_type: "rss" | "link" | "idea";
  source_ref?: string;
  title?: string;
  content: string;
  hashtags?: string;
}

export function createDraft(d: NewDraft): number {
  const info = db
    .prepare(
      `INSERT INTO drafts (source_type, source_ref, title, content, hashtags)
       VALUES (@source_type, @source_ref, @title, @content, @hashtags)`,
    )
    .run({
      source_type: d.source_type,
      source_ref: d.source_ref ?? null,
      title: d.title ?? null,
      content: d.content,
      hashtags: d.hashtags ?? null,
    });
  return Number(info.lastInsertRowid);
}

export function updateDraftContent(id: number, content: string, hashtags: string): void {
  db.prepare(
    "UPDATE drafts SET content = ?, hashtags = ?, updated_at = datetime('now') WHERE id = ?",
  ).run(content, hashtags, id);
}

export function setDraftStatus(id: number, status: Draft["status"]): void {
  db.prepare("UPDATE drafts SET status = ?, updated_at = datetime('now') WHERE id = ?").run(
    status,
    id,
  );
}

/** Compose the final post text (body + a blank line + hashtags). */
export function composePostText(d: Draft): string {
  const tags = (d.hashtags || "").trim();
  return tags ? `${d.content.trim()}\n\n${tags}` : d.content.trim();
}

/** Publish a draft to LinkedIn and record the result. Throws on failure. */
export async function publishDraft(id: number): Promise<string> {
  const draft = getDraft(id);
  if (!draft) throw new Error("Draft not found");
  if (draft.status === "published") return draft.li_post_urn || "(already published)";

  try {
    const urn = await publishPost(composePostText(draft));
    db.prepare(
      `UPDATE drafts SET status = 'published', li_post_urn = ?, error = NULL,
        published_at = datetime('now'), updated_at = datetime('now') WHERE id = ?`,
    ).run(urn, id);
    return urn;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    db.prepare("UPDATE drafts SET error = ?, updated_at = datetime('now') WHERE id = ?").run(
      msg,
      id,
    );
    throw err;
  }
}

/** Rough duplicate guard: has a very similar post body been created recently? */
export function looksDuplicate(content: string): boolean {
  const norm = content.trim().slice(0, 80).toLowerCase();
  const recent = db
    .prepare("SELECT content FROM drafts ORDER BY created_at DESC LIMIT 50")
    .all() as { content: string }[];
  return recent.some((r) => r.content.trim().slice(0, 80).toLowerCase() === norm);
}
