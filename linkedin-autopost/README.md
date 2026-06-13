# linkedin-autopost

An autonomous-ish LinkedIn content pipeline. On a schedule it gathers material,
writes post **drafts** with Claude, and queues them for you to review. Nothing is
published to LinkedIn until you approve and click **Publish** — a human gate by
design.

## What it does

```
 sources ──────────────►  Claude  ─────►  drafts  ──(you approve)──►  LinkedIn
 • RSS / news feeds        (ghostwrites    (web UI:                    (Posts API,
 • links you paste in       in your voice)  edit / approve / reject)    w_member_social)
 • LLM-generated ideas
```

Three content sources, all configurable in the UI:

- **RSS / news feeds** — fresh items get summarized and turned into a post that adds *your* take.
- **Saved links** — paste an article URL; the next run fetches, summarizes, and drafts from it.
- **LLM topic ideas** — Claude proposes specific post angles grounded in your profile/themes.

A daily cron run (configurable) creates up to `MAX_DRAFTS_PER_RUN` drafts. You can
also hit **Generate now**.

> ### Why "drafts only" and not fully automatic?
> LinkedIn's official API can **publish** posts (`w_member_social` via the Posts
> API) but does **not** let apps read your feed or fetch "top posts" connected to
> your profile — that's why inspiration comes from RSS / links / LLM ideas rather
> than scraping LinkedIn. And there's no reliable personal-profile "draft" object
> in the API, so drafts live in this app's database until you publish them. You
> chose a human approval gate; flip `lifecycleState` / wire `runPipeline` →
> `publishDraft` if you ever want full auto.

## Quick start (local)

```bash
cp .env.example .env      # then fill in the values (see below)
npm install
npm run dev               # http://localhost:3000
```

Open the app → **Settings** → fill in your profile → **Connect LinkedIn**. Add
feeds/links under **Sources**. Click **Generate now** on the dashboard.

## Configuration (`.env`)

| Var | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes (to generate) | Your Claude API key. Model defaults to `claude-opus-4-8` (`CLAUDE_MODEL` to override). |
| `LINKEDIN_CLIENT_ID` / `LINKEDIN_CLIENT_SECRET` | yes (to publish) | From your LinkedIn developer app. |
| `BASE_URL` | for OAuth | Public URL of the app; the OAuth redirect is `<BASE_URL>/auth/linkedin/callback`. |
| `APP_PASSWORD` | recommended | Gates the UI. **If unset the UI is open** — only OK on localhost. |
| `SESSION_SECRET` | recommended | Signs the login cookie. |
| `GENERATE_CRON` | no | Cron for the auto run. Default `0 8 * * *` (08:00 daily, server time). |
| `MAX_DRAFTS_PER_RUN` | no | Default 3. |
| `LLM_IDEAS_PER_RUN` | no | Default 4. |

### Setting up the LinkedIn app

1. Create an app at <https://www.linkedin.com/developers/apps>.
2. Request the **Sign In with LinkedIn using OpenID Connect** and **Share on
   LinkedIn** products (the latter grants `w_member_social`, required to post).
3. Under **Auth**, add an authorized redirect URL:
   `<BASE_URL>/auth/linkedin/callback` (e.g. `http://localhost:3000/auth/linkedin/callback`).
4. Copy the Client ID/Secret into `.env`.

## Deploy (Fly.io)

```bash
fly launch --no-deploy
fly volumes create data --size 1
fly secrets set ANTHROPIC_API_KEY=... LINKEDIN_CLIENT_ID=... LINKEDIN_CLIENT_SECRET=... \
  APP_PASSWORD=... SESSION_SECRET=... BASE_URL=https://<your-app>.fly.dev
fly deploy
```

Then add `https://<your-app>.fly.dev/auth/linkedin/callback` as a redirect URL in
the LinkedIn app. `auto_stop_machines` is off so the scheduler keeps firing.

## Project layout

```
src/
  config.ts        env config + warnings
  db.ts            SQLite schema + settings/profile helpers
  claude.ts        idea generation, draft writing, summarization (Anthropic SDK)
  linkedin.ts      OAuth + publish (Posts API)
  drafts.ts        draft CRUD + publish
  pipeline.ts      the generation pass (links → RSS → ideas)
  scheduler.ts     cron
  sources/rss.ts   feed fetching + dedupe
  sources/links.ts URL fetch + readable-text extraction
  server.ts        Express routes + auth
  views.ts         server-rendered HTML
public/styles.css
```

## Notes & limits

- Personal-profile posting only (no organization pages yet — add `w_organization_social`
  and an org URN author to extend).
- LinkedIn access tokens last ~60 days; reconnect from **Settings** when expired.
  (Refresh tokens are stored if your app is approved for them.)
- This is a single-user tool. The password gate is intentionally simple.
