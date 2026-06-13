import Anthropic from "@anthropic-ai/sdk";
import { config } from "./config.js";
import type { Profile } from "./db.js";
import { logger } from "./logger.js";

// Lazily construct so the app can boot (and serve the settings page) even when
// no API key is configured yet.
let _client: Anthropic | null = null;
function client(): Anthropic {
  if (!config.anthropicApiKey) {
    throw new Error("ANTHROPIC_API_KEY is not set — cannot call Claude.");
  }
  if (!_client) _client = new Anthropic({ apiKey: config.anthropicApiKey });
  return _client;
}

function profileBlock(p: Profile): string {
  const lines: string[] = [];
  if (p.name) lines.push(`Name: ${p.name}`);
  if (p.headline) lines.push(`Headline: ${p.headline}`);
  if (p.about) lines.push(`About / audience / voice:\n${p.about}`);
  if (p.themes.length) lines.push(`Recurring themes: ${p.themes.join(", ")}`);
  return lines.length ? lines.join("\n") : "(No profile details provided yet.)";
}

/**
 * Call Claude and return the text of the first text block. Uses streaming +
 * finalMessage so long generations don't trip request timeouts.
 */
async function complete(system: string, user: string, maxTokens = 2000): Promise<string> {
  const stream = client().messages.stream({
    model: config.claudeModel,
    max_tokens: maxTokens,
    system,
    messages: [{ role: "user", content: user }],
  });
  const msg = await stream.finalMessage();
  const text = msg.content
    .filter((b): b is Anthropic.TextBlock => b.type === "text")
    .map((b) => b.text)
    .join("\n")
    .trim();
  return text;
}

/**
 * Robustly pull a JSON value out of a model response. Handles bare JSON,
 * ```json fenced blocks, and leading/trailing prose.
 */
function extractJSON<T>(text: string): T {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1] : text;
  // Find the first balanced { } or [ ] span.
  const start = candidate.search(/[[{]/);
  if (start === -1) throw new Error("No JSON found in model output");
  const open = candidate[start];
  const close = open === "{" ? "}" : "]";
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let i = start; i < candidate.length; i++) {
    const c = candidate[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
    } else if (c === '"') inStr = true;
    else if (c === open) depth++;
    else if (c === close) {
      depth--;
      if (depth === 0) {
        return JSON.parse(candidate.slice(start, i + 1)) as T;
      }
    }
  }
  throw new Error("Unbalanced JSON in model output");
}

export interface GeneratedDraft {
  /** Short internal label so the user can scan the list. */
  title: string;
  /** The full post body, ready to publish. */
  content: string;
  /** Space-separated hashtags, e.g. "#AI #Leadership". */
  hashtags: string;
}

const STYLE_RULES = `Write in first person as the profile owner. Hook in the first line.
Keep it punchy and skimmable: short paragraphs or line breaks, no walls of text.
No clickbait, no emoji spam (one or two at most, only if it fits the voice).
Aim for 90–200 words. End with a light question or call to reflection when natural.
Never invent statistics, quotes, or facts. If a source is summarized, stay faithful to it.
Do not include the hashtags inside the body — return them separately.`;

/** Generate fresh post topic ideas grounded in the user's profile/themes. */
export async function generateIdeas(profile: Profile, count: number): Promise<string[]> {
  const system =
    "You are a LinkedIn content strategist. You propose concrete, specific post ideas " +
    "tailored to the person's expertise and audience. Avoid generic motivational fluff.";
  const user = `Here is the profile:\n${profileBlock(profile)}\n\n` +
    `Propose ${count} distinct, specific LinkedIn post ideas this person could authentically write this week. ` +
    `Each idea should be one sentence describing the angle.\n\n` +
    `Respond ONLY with JSON: {"ideas": ["idea one", "idea two", ...]}`;
  const out = await complete(system, user, 1200);
  const parsed = extractJSON<{ ideas: string[] }>(out);
  return (parsed.ideas ?? []).filter((s) => typeof s === "string" && s.trim()).slice(0, count);
}

interface SeedInput {
  kind: "rss" | "link" | "idea";
  title?: string;
  url?: string;
  /** Article text / summary / the idea itself. */
  material: string;
}

/** Turn a single seed (article, link, or idea) into a publish-ready draft. */
export async function generateDraft(profile: Profile, seed: SeedInput): Promise<GeneratedDraft> {
  const system =
    "You are ghostwriting LinkedIn posts for the profile owner. You match their voice and " +
    `expertise. Follow these rules strictly:\n${STYLE_RULES}`;

  let context = "";
  if (seed.kind === "idea") {
    context = `Write a post based on this idea:\n"${seed.material}"`;
  } else {
    context =
      `Write a post reacting to / sharing takeaways from this source. ` +
      `Add the profile owner's own perspective; don't just summarize.\n\n` +
      (seed.title ? `Source title: ${seed.title}\n` : "") +
      (seed.url ? `Source URL: ${seed.url}\n` : "") +
      `Source content:\n${seed.material.slice(0, 6000)}`;
  }

  const user =
    `Profile:\n${profileBlock(profile)}\n\n${context}\n\n` +
    `Respond ONLY with JSON of the form:\n` +
    `{"title": "<3-6 word internal label>", "content": "<the post body>", "hashtags": "#Tag1 #Tag2 #Tag3"}`;

  const out = await complete(system, user, 2000);
  const parsed = extractJSON<GeneratedDraft>(out);
  if (!parsed.content || !parsed.content.trim()) {
    throw new Error("Model returned an empty post body");
  }
  return {
    title: (parsed.title || seed.title || "Untitled").trim().slice(0, 120),
    content: parsed.content.trim(),
    hashtags: (parsed.hashtags || "").trim(),
  };
}

/** Summarize fetched article text down to the key points (used for saved links). */
export async function summarizeArticle(title: string, text: string): Promise<string> {
  const system = "You extract the key points of an article concisely and faithfully.";
  const user =
    `Title: ${title}\n\nArticle:\n${text.slice(0, 12000)}\n\n` +
    `Summarize the main argument and 3-5 key takeaways in plain prose. No preamble.`;
  try {
    return await complete(system, user, 800);
  } catch (err) {
    logger.warn("summarizeArticle failed, using raw excerpt", err);
    return text.slice(0, 2000);
  }
}
