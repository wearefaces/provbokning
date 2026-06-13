import type { Draft, Feed, SavedLink, Profile } from "./db.js";
import type { ConnectionStatus } from "./linkedin.js";

export function esc(s: unknown): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function layout(title: string, body: string, active: string): string {
  const tab = (href: string, label: string, key: string) =>
    `<a href="${href}" class="${active === key ? "active" : ""}">${label}</a>`;
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${esc(title)} · LinkedIn Autopost</title>
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>
  <header class="topbar">
    <div class="brand">in · autopost</div>
    <nav>
      ${tab("/", "Drafts", "drafts")}
      ${tab("/sources", "Sources", "sources")}
      ${tab("/settings", "Settings", "settings")}
    </nav>
  </header>
  <main>${body}</main>
  <footer>Drafts-only mode — nothing is posted to LinkedIn until you approve it.</footer>
</body>
</html>`;
}

function flash(msg?: string, kind: "ok" | "err" = "ok"): string {
  if (!msg) return "";
  return `<div class="flash ${kind}">${esc(msg)}</div>`;
}

function statusBadge(status: string): string {
  return `<span class="badge ${esc(status)}">${esc(status)}</span>`;
}

function sourceBadge(t: string): string {
  const label = t === "rss" ? "RSS" : t === "link" ? "Link" : "Idea";
  return `<span class="src ${esc(t)}">${label}</span>`;
}

// ---------------- Drafts page ----------------

export function renderDrafts(opts: {
  drafts: Draft[];
  connection: ConnectionStatus;
  generating: boolean;
  lastRun?: { finishedAt: string; created: number; errors: string[] } | null;
  flash?: string;
  flashKind?: "ok" | "err";
}): string {
  const { drafts, connection, generating, lastRun } = opts;

  const conn = connection.connected
    ? `<span class="ok-dot"></span> Connected as <strong>${esc(connection.name)}</strong>` +
      (connection.expired ? ` <span class="badge rejected">token expired</span>` : "")
    : `<span class="off-dot"></span> Not connected — <a href="/settings">connect LinkedIn</a> to publish`;

  const last = lastRun
    ? `Last run ${esc(lastRun.finishedAt)} — created ${lastRun.created} draft(s)` +
      (lastRun.errors.length ? `, ${lastRun.errors.length} error(s)` : "")
    : "No runs yet.";

  const cards = drafts.length
    ? drafts.map((d) => draftCard(d, connection)).join("\n")
    : `<p class="empty">No drafts yet. Click <em>Generate now</em> or wait for the next scheduled run.</p>`;

  const body = `
  ${flash(opts.flash, opts.flashKind)}
  <section class="status-row">
    <div class="conn">${conn}</div>
    <form method="post" action="/api/generate" class="inline">
      <button ${generating ? "disabled" : ""} class="primary">${generating ? "Generating…" : "Generate now"}</button>
    </form>
  </section>
  <p class="muted">${esc(last)}</p>
  <section class="cards">${cards}</section>`;
  return layout("Drafts", body, "drafts");
}

function draftCard(d: Draft, connection: ConnectionStatus): string {
  const canPublish =
    connection.connected && !connection.expired && (d.status === "draft" || d.status === "approved");
  const fullText = d.hashtags ? `${d.content}\n\n${d.hashtags}` : d.content;
  return `
  <article class="card">
    <div class="card-head">
      ${sourceBadge(d.source_type)} ${statusBadge(d.status)}
      <span class="card-title">${esc(d.title || "Untitled")}</span>
      <span class="when">${esc(d.created_at)}</span>
    </div>
    ${d.error ? `<div class="flash err">${esc(d.error)}</div>` : ""}
    <form method="post" action="/api/drafts/${d.id}/save" class="edit">
      <textarea name="content" rows="7">${esc(d.content)}</textarea>
      <input type="text" name="hashtags" value="${esc(d.hashtags || "")}" placeholder="#hashtags" />
      <div class="card-actions">
        <button class="ghost" type="submit">Save edits</button>
        ${
          d.status === "draft"
            ? `<button class="ghost" formaction="/api/drafts/${d.id}/approve">Approve</button>`
            : ""
        }
        ${
          canPublish
            ? `<button class="primary" formaction="/api/drafts/${d.id}/publish">Publish to LinkedIn</button>`
            : ""
        }
        ${
          d.status !== "published"
            ? `<button class="danger" formaction="/api/drafts/${d.id}/reject">Reject</button>`
            : ""
        }
        ${
          d.li_post_urn
            ? `<span class="muted">posted: ${esc(d.li_post_urn)}</span>`
            : ""
        }
      </div>
    </form>
    ${d.source_ref && d.source_type !== "idea" ? `<div class="srcref">Source: <a href="${esc(d.source_ref)}" target="_blank" rel="noopener">${esc(d.source_ref)}</a></div>` : ""}
    <details class="preview"><summary>Preview final post</summary><pre>${esc(fullText)}</pre></details>
  </article>`;
}

// ---------------- Sources page ----------------

export function renderSources(opts: {
  feeds: Feed[];
  links: SavedLink[];
  flash?: string;
  flashKind?: "ok" | "err";
}): string {
  const feedRows = opts.feeds.length
    ? opts.feeds
        .map(
          (f) => `<li>
        <span>${esc(f.title || f.url)}</span>
        <span class="muted">${esc(f.url)}</span>
        <form method="post" action="/api/feeds/${f.id}/delete" class="inline">
          <button class="danger small">remove</button>
        </form>
      </li>`,
        )
        .join("")
    : `<li class="empty">No feeds yet.</li>`;

  const linkRows = opts.links.length
    ? opts.links
        .map(
          (l) => `<li>
        <span><a href="${esc(l.url)}" target="_blank" rel="noopener">${esc(l.url)}</a></span>
        ${statusBadge(l.status)}
        ${l.note ? `<span class="muted">${esc(l.note)}</span>` : ""}
        ${l.error ? `<span class="flash err inline-err">${esc(l.error)}</span>` : ""}
        <form method="post" action="/api/links/${l.id}/delete" class="inline">
          <button class="danger small">remove</button>
        </form>
      </li>`,
        )
        .join("")
    : `<li class="empty">No saved links.</li>`;

  const body = `
  ${flash(opts.flash, opts.flashKind)}
  <section class="panel">
    <h2>RSS / news feeds</h2>
    <p class="muted">The bot pulls fresh items from these and drafts posts reacting to them.</p>
    <form method="post" action="/api/feeds" class="row">
      <input type="url" name="url" placeholder="https://example.com/feed.xml" required />
      <button class="primary">Add feed</button>
    </form>
    <ul class="list">${feedRows}</ul>
  </section>

  <section class="panel">
    <h2>Saved links</h2>
    <p class="muted">Drop in an article URL; the next run fetches it, summarizes it, and drafts a post.</p>
    <form method="post" action="/api/links" class="row">
      <input type="url" name="url" placeholder="https://…" required />
      <input type="text" name="note" placeholder="optional angle / note" />
      <button class="primary">Add link</button>
    </form>
    <ul class="list">${linkRows}</ul>
  </section>`;
  return layout("Sources", body, "sources");
}

// ---------------- Settings page ----------------

export function renderSettings(opts: {
  profile: Profile;
  connection: ConnectionStatus;
  linkedinConfigured: boolean;
  warnings: string[];
  cron: string;
  flash?: string;
  flashKind?: "ok" | "err";
}): string {
  const { profile, connection, linkedinConfigured } = opts;

  const connBox = !linkedinConfigured
    ? `<p class="muted">Set <code>LINKEDIN_CLIENT_ID</code> and <code>LINKEDIN_CLIENT_SECRET</code> in your environment, then restart.</p>`
    : connection.connected
      ? `<p><span class="ok-dot"></span> Connected as <strong>${esc(connection.name)}</strong>
         ${connection.expired ? `<span class="badge rejected">expired</span>` : ""}</p>
         <form method="post" action="/auth/linkedin/disconnect" class="inline"><button class="danger">Disconnect</button></form>
         <a class="btn" href="/auth/linkedin">Reconnect</a>`
      : `<a class="btn primary" href="/auth/linkedin">Connect LinkedIn</a>`;

  const warn = opts.warnings.length
    ? `<div class="flash err"><strong>Heads up:</strong><ul>${opts.warnings
        .map((w) => `<li>${esc(w)}</li>`)
        .join("")}</ul></div>`
    : "";

  const body = `
  ${flash(opts.flash, opts.flashKind)}
  ${warn}
  <section class="panel">
    <h2>LinkedIn connection</h2>
    ${connBox}
  </section>

  <section class="panel">
    <h2>Your profile (steers the writing)</h2>
    <p class="muted">The more you fill in, the more the drafts sound like you. Schedule: <code>${esc(opts.cron)}</code></p>
    <form method="post" action="/api/profile" class="stack">
      <label>Name<input type="text" name="name" value="${esc(profile.name)}" /></label>
      <label>Headline<input type="text" name="headline" value="${esc(profile.headline)}" placeholder="e.g. Insurance product lead @ Länsförsäkringar" /></label>
      <label>About / audience / voice
        <textarea name="about" rows="5" placeholder="Who you are, who you're writing for, your tone, what you want to be known for.">${esc(profile.about)}</textarea>
      </label>
      <label>Themes (comma-separated)
        <input type="text" name="themes" value="${esc(profile.themes.join(", "))}" placeholder="insurtech, leadership, AI in finance" />
      </label>
      <button class="primary">Save profile</button>
    </form>
  </section>`;
  return layout("Settings", body, "settings");
}

// ---------------- Login page ----------------

export function renderLogin(error?: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Sign in · LinkedIn Autopost</title><link rel="stylesheet" href="/styles.css" /></head>
<body class="login-page">
  <form method="post" action="/login" class="login">
    <h1>in · autopost</h1>
    ${error ? `<div class="flash err">${esc(error)}</div>` : ""}
    <input type="password" name="password" placeholder="Password" autofocus required />
    <button class="primary">Sign in</button>
  </form>
</body></html>`;
}
