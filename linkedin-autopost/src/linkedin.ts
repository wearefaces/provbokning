import { config, linkedinRedirectUri } from "./config.js";
import { getJSON, setJSON, setSetting } from "./db.js";
import { logger } from "./logger.js";

// LinkedIn endpoints
const AUTH_URL = "https://www.linkedin.com/oauth/v2/authorization";
const TOKEN_URL = "https://www.linkedin.com/oauth/v2/accessToken";
const USERINFO_URL = "https://api.linkedin.com/v2/userinfo";
const POSTS_URL = "https://api.linkedin.com/rest/posts";

interface StoredToken {
  accessToken: string;
  refreshToken?: string;
  // epoch ms when the access token expires
  expiresAt: number;
  authorUrn: string; // urn:li:person:XXXX
  name: string;
}

const TOKEN_KEY = "linkedin_token";

export function getToken(): StoredToken | null {
  const t = getJSON<StoredToken | null>(TOKEN_KEY, null);
  return t && t.accessToken ? t : null;
}

export interface ConnectionStatus {
  connected: boolean;
  name?: string;
  expiresAt?: number;
  expired?: boolean;
}

export function connectionStatus(): ConnectionStatus {
  const t = getToken();
  if (!t) return { connected: false };
  return {
    connected: true,
    name: t.name,
    expiresAt: t.expiresAt,
    expired: Date.now() >= t.expiresAt,
  };
}

export function disconnect(): void {
  setSetting(TOKEN_KEY, "");
}

export function isConfigured(): boolean {
  return Boolean(config.linkedin.clientId && config.linkedin.clientSecret);
}

/** Build the authorization URL the user clicks to grant access. */
export function authorizeUrl(state: string): string {
  const params = new URLSearchParams({
    response_type: "code",
    client_id: config.linkedin.clientId,
    redirect_uri: linkedinRedirectUri,
    scope: config.linkedin.scopes,
    state,
  });
  return `${AUTH_URL}?${params.toString()}`;
}

/** Exchange the auth code for tokens and fetch the member identity. */
export async function exchangeCode(code: string): Promise<StoredToken> {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: linkedinRedirectUri,
    client_id: config.linkedin.clientId,
    client_secret: config.linkedin.clientSecret,
  });

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) {
    throw new Error(`Token exchange failed (${res.status}): ${await res.text()}`);
  }
  const json = (await res.json()) as {
    access_token: string;
    expires_in: number;
    refresh_token?: string;
    refresh_token_expires_in?: number;
  };

  const identity = await fetchUserinfo(json.access_token);

  const token: StoredToken = {
    accessToken: json.access_token,
    refreshToken: json.refresh_token,
    expiresAt: Date.now() + json.expires_in * 1000,
    authorUrn: `urn:li:person:${identity.sub}`,
    name: identity.name ?? "LinkedIn member",
  };
  setJSON(TOKEN_KEY, token);
  logger.info(`LinkedIn connected as ${token.name} (${token.authorUrn})`);
  return token;
}

interface Userinfo {
  sub: string;
  name?: string;
  email?: string;
}

async function fetchUserinfo(accessToken: string): Promise<Userinfo> {
  const res = await fetch(USERINFO_URL, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) {
    throw new Error(
      `Could not fetch LinkedIn userinfo (${res.status}): ${await res.text()}. ` +
        `Make sure the 'openid' and 'profile' scopes are granted.`,
    );
  }
  return (await res.json()) as Userinfo;
}

export class LinkedInError extends Error {}

/**
 * Publish a post to the member's feed via the versioned Posts API.
 * Returns the created post URN.
 */
export async function publishPost(text: string): Promise<string> {
  const token = getToken();
  if (!token) throw new LinkedInError("LinkedIn is not connected.");
  if (Date.now() >= token.expiresAt) {
    throw new LinkedInError("LinkedIn token has expired — reconnect on the dashboard.");
  }

  const payload = {
    author: token.authorUrn,
    commentary: text,
    visibility: "PUBLIC",
    distribution: {
      feedDistribution: "MAIN_FEED",
      targetEntities: [],
      thirdPartyDistributionChannels: [],
    },
    lifecycleState: "PUBLISHED",
    isReshareDisabledByAuthor: false,
  };

  const res = await fetch(POSTS_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token.accessToken}`,
      "Content-Type": "application/json",
      "X-Restli-Protocol-Version": "2.0.0",
      "LinkedIn-Version": config.linkedin.apiVersion,
    },
    body: JSON.stringify(payload),
  });

  if (res.status !== 201 && res.status !== 200) {
    throw new LinkedInError(`LinkedIn publish failed (${res.status}): ${await res.text()}`);
  }
  // The created post URN is returned in the x-restli-id header (or x-linkedin-id).
  const urn =
    res.headers.get("x-restli-id") ||
    res.headers.get("x-linkedin-id") ||
    "(unknown)";
  logger.info(`Published LinkedIn post ${urn}`);
  return urn;
}
