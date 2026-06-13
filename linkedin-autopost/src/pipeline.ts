import { config } from "./config.js";
import { generateDraft, generateIdeas, summarizeArticle } from "./claude.js";
import { getProfile, setSetting } from "./db.js";
import { createDraft, looksDuplicate } from "./drafts.js";
import { fetchArticle, listLinks, setLinkStatus } from "./sources/links.js";
import { fetchFreshItems, markSeen } from "./sources/rss.js";
import type { FeedItem } from "./sources/rss.js";
import { logger } from "./logger.js";

export interface PipelineResult {
  created: number;
  errors: string[];
  startedAt: string;
  finishedAt: string;
}

let running = false;

export function isRunning(): boolean {
  return running;
}

/**
 * One full generation pass:
 *   1. saved links the user dropped in (highest intent)
 *   2. fresh RSS items
 *   3. LLM-generated topic ideas (fills the rest)
 * Each produces at most `MAX_DRAFTS_PER_RUN` drafts in total.
 */
export async function runPipeline(): Promise<PipelineResult> {
  if (running) {
    return {
      created: 0,
      errors: ["A generation run is already in progress."],
      startedAt: new Date().toISOString(),
      finishedAt: new Date().toISOString(),
    };
  }
  running = true;
  const startedAt = new Date().toISOString();
  const errors: string[] = [];
  let created = 0;
  const profile = getProfile();
  const budget = Math.max(1, config.maxDraftsPerRun);

  try {
    logger.info(`Pipeline start (budget ${budget} drafts)`);

    // 1) Saved links --------------------------------------------------------
    for (const link of listLinks("pending")) {
      if (created >= budget) break;
      try {
        const article = await fetchArticle(link.url);
        const summary = await summarizeArticle(article.title, article.text);
        const draft = await generateDraft(profile, {
          kind: "link",
          title: article.title,
          url: link.url,
          material: link.note ? `${link.note}\n\n${summary}` : summary,
        });
        if (!looksDuplicate(draft.content)) {
          createDraft({
            source_type: "link",
            source_ref: link.url,
            title: draft.title,
            content: draft.content,
            hashtags: draft.hashtags,
          });
          created++;
        }
        setLinkStatus(link.id, "used");
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        errors.push(`link ${link.url}: ${msg}`);
        setLinkStatus(link.id, "error", msg);
      }
    }

    // 2) RSS items ----------------------------------------------------------
    if (created < budget) {
      let items: FeedItem[] = [];
      try {
        items = await fetchFreshItems();
      } catch (err) {
        errors.push(`rss: ${err instanceof Error ? err.message : String(err)}`);
      }
      for (const item of items) {
        if (created >= budget) break;
        try {
          const material =
            item.snippet && item.snippet.length > 120
              ? item.snippet
              : await safeFetchSummary(item);
          const draft = await generateDraft(profile, {
            kind: "rss",
            title: item.title,
            url: item.url,
            material,
          });
          if (!looksDuplicate(draft.content)) {
            createDraft({
              source_type: "rss",
              source_ref: item.url,
              title: draft.title,
              content: draft.content,
              hashtags: draft.hashtags,
            });
            created++;
          }
          markSeen(item);
        } catch (err) {
          errors.push(`rss ${item.url}: ${err instanceof Error ? err.message : String(err)}`);
          markSeen(item); // don't retry a broken item forever
        }
      }
    }

    // 3) LLM ideas ----------------------------------------------------------
    if (created < budget && config.llmIdeasPerRun > 0) {
      try {
        const ideas = await generateIdeas(profile, config.llmIdeasPerRun);
        for (const idea of ideas) {
          if (created >= budget) break;
          try {
            const draft = await generateDraft(profile, { kind: "idea", material: idea });
            if (!looksDuplicate(draft.content)) {
              createDraft({
                source_type: "idea",
                source_ref: idea,
                title: draft.title,
                content: draft.content,
                hashtags: draft.hashtags,
              });
              created++;
            }
          } catch (err) {
            errors.push(`idea: ${err instanceof Error ? err.message : String(err)}`);
          }
        }
      } catch (err) {
        errors.push(`ideas: ${err instanceof Error ? err.message : String(err)}`);
      }
    }

    logger.info(`Pipeline done: ${created} drafts, ${errors.length} errors`);
  } finally {
    running = false;
  }

  const finishedAt = new Date().toISOString();
  setSetting("last_run", JSON.stringify({ startedAt, finishedAt, created, errors }));
  return { created, errors, startedAt, finishedAt };
}

async function safeFetchSummary(item: FeedItem): Promise<string> {
  if (!item.url) return item.title;
  try {
    const article = await fetchArticle(item.url);
    return await summarizeArticle(article.title || item.title, article.text);
  } catch {
    return item.snippet || item.title;
  }
}
