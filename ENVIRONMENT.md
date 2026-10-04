# Environment

Everything needed to run a command: accounts, regions, versions, MCP setup, and the gotchas that
cost time if you hit them cold.

---

## 1. Accounts

| Service | Account | Identifier |
|---|---|---|
| Supabase | `ahmedmelgammal6@gmail.com` | project **`marketak`** · ref `erxxsebcqqcpkipzcdhg` |
| Cloudflare | `ahmedmelgammal6@gmail.com` | `8ae79d52c8b84a170bcb5c4c0485f34c` |
| Firebase | `ahmedmelgammal6@gmail.com` | project **`marketak-eg`** · number `283007295790` |

### Live connection details

| Thing | Value |
|---|---|
| Supabase URL | `https://erxxsebcqqcpkipzcdhg.supabase.co` |
| Supabase publishable key | `sb_publishable_RHsYSwhbXBo1vzy4NHQdZA_RG8kzY8j` |
| Legacy anon key | present in the dashboard; prefer the `sb_publishable_` key |
| DB host | `db.erxxsebcqqcpkipzcdhg.supabase.co` |
| Postgres | 17.11.0.002 (engine 17, GA channel) |
| Supabase org | `irlojawfmoffhueecvsa` |

The publishable key is public by design and safe to commit. The **service-role key is not** and
must only ever live in Worker secrets.

---

## 1a. Blockers requiring dashboard access

| # | Blocker | Why it matters | Who |
|---|---|---|---|
| 1a.1 | **Enable R2** in the Cloudflare dashboard | R2 returns `403 Please enable R2 through the Cloudflare Dashboard`. Images, menu snapshots, archives and backups all depend on it. This is the single most important free-tier decision — serving images from Supabase instead is a 5–30× egress overrun | Manual |
| 1a.2 | R2 may require a payment method at signup | If so, it is still ~$0/month at our volume, but it must be added | Manual |
| 1a.3 | **Apple Developer account** | iOS push via FCM needs an APNs key uploaded to the Firebase console. Until then iOS receives **no push notifications at all** | Manual |

---

## 2. Infrastructure choices

| Thing | Value | Why |
|---|---|---|
| Supabase project name | `marketak` | Display name **Marketak / ماركتك** |
| Supabase region | `eu-central-1` (Frankfurt) | ADR 10. ~100–130 ms from Egypt; accepted against a 900 ms p95 target |
| Supabase extensions available | `pg_trgm` 1.6, `btree_gist` 1.7, `unaccent` 1.1, `pg_cron` 1.6.4, `pg_net` 0.20.4, `pgtap` 1.3.3, `pg_partman` 5.3.1, `earthdistance` 1.2, `citext`, `pgcrypto` 1.3 *(installed)* | Verified on the live project. `pg_tap` matters: it means the RLS policy tests in migration 022 actually run |
| PostGIS | **available**, 3.3.7 | Not needed — the design uses geohash prefixes. Recorded because it resolves open question 4.4 |
| R2 buckets | `marketak-public`, `marketak-private` | Prefixed to avoid collisions. **Cannot create until R2 is enabled in the dashboard** |
| Firebase project | `marketak-eg` | `marketak` was already taken globally. FCM + Crashlytics + Analytics only; Auth, Firestore, Storage, Functions, Hosting and Remote Config are all **excluded by design** |
| SQLCipher keys | Android Keystore, non-exportable | No backup key — a recoverable key defeats the purpose |

---

## 3. Toolchain

| Tool | Version | Notes |
|---|---|---|
| Node.js | v22.16.0 | |
| npm | 10.9.2 | |
| `supabase` | 2.119.0 | Installed globally. **Requires Docker for `supabase start`** |
| `wrangler` | 4.86.0 | Pre-installed. Logged in via OAuth |
| `firebase` | 15.18.0 CLI; `npx` resolves 15.32.1 | Pre-installed, logged in |
| `git` | present | |
| `gh` | present | |
| **Docker** | **NOT INSTALLED** | `supabase start` cannot run. See §6 |

Project root is `C:\Users\A-Dev\Desktop\delivery app`. **The path contains a space**, which is a known
source of friction with `wrangler`, the Supabase CLI's Docker bind mounts, and Docker Desktop on
Windows. It was chosen deliberately to stay put. If you hit a quoting or mount failure, this is why —
do not spend an hour debugging the tool.

---

## 4. MCP servers

Configured in `~/.config/opencode/opencode.jsonc` (global — these load in every project).

| Server | Type | Status |
|---|---|---|
| `cloudflare` | remote, OAuth | connected |
| `cloudflare-docs` | remote, public | connected, no auth needed |
| `cloudflare-bindings` | remote, OAuth | connected |
| `cloudflare-builds` | remote, OAuth | connected |
| `cloudflare-observability` | remote, OAuth | connected |
| `supabase` | remote, OAuth | connected |
| `firebase` | **local stdio** | connected |
| `stitch`, `playwright` | — | pre-existing |
| `revenuecat` | remote | **needs auth** — pre-existing, unrelated to this project |

### 4.1 Gotcha: Firebase MCP is not an OAuth server

`opencode mcp auth firebase` **always fails** with *"not an OAuth-capable remote server."* That is
correct behaviour, not an error. The Firebase MCP is a local stdio server that inherits the
credentials of the already-authenticated `firebase` CLI. Authenticating it means running
`firebase login`, not anything inside opencode.

### 4.2 Gotcha: the first `firebase` MCP start times out

The config uses `npx -y firebase-tools@latest mcp`. The first launch downloads ~50 MB and exceeds
opencode's 30-second MCP startup timeout, reporting `Operation timed out after 30000ms`. The cache is
now warm, so it starts in about 6 seconds and connects. If it ever fails again after an npm-side
change, run this once by hand to re-warm the cache:

```
npx -y firebase-tools@latest mcp --help
```

### 4.3 Scope the Supabase MCP to one project

Unscoped, the Supabase MCP has access to **every** project in the account. Once real orders exist,
scope it and add a separate read-only entry for read work:

```jsonc
"supabase": {
  "type": "remote",
  "url": "https://mcp.supabase.com/mcp?project_ref=erxxsebcqqcpkipzcdhg",
  "enabled": true,
  "oauth": {}
},
"supabase-readonly": {
  "type": "remote",
  "url": "https://mcp.supabase.com/mcp?project_ref=erxxsebcqqcpkipzcdhg&read_only=true",
  "enabled": true,
  "oauth": {}
}
```

Restricting feature groups with `?features=database,docs` cuts the tool surface further. The
`&read_only=true` variant executes SQL as a read-only Postgres role and is the right default for
diagnostics and unattended checks.

### 4.4 Gotcha: `wrangler login` is not Cloudflare MCP auth

They are separate OAuth clients. `wrangler whoami` succeeding does **not** mean the MCP servers are
authenticated. Each needs `opencode mcp auth <name>`.

### 4.5 Re-authenticating

```
opencode mcp auth cloudflare
opencode mcp auth cloudflare-bindings
opencode mcp auth cloudflare-builds
opencode mcp auth cloudflare-observability
opencode mcp auth supabase
```

Verify with `opencode mcp list`. **Restart opencode after editing `opencode.jsonc`** — MCP config is
read once at startup and is not hot-reloaded, so tools stay invisible until you do.

---

## 5. Agent skills

Installed to `~/.agents/skills` and `~/.claude/skills`. Both are auto-loaded by opencode, so all of
them enter the context of every session in every project.

| Pack | Count | Install command |
|---|---|---|
| Cloudflare | 16 | `npx -y skills add cloudflare/skills --skill '*' --yes --global` |
| Firebase | 13 | `npx -y skills add firebase/agent-skills --yes --global` |
| Supabase | 2 | `npx -y skills add supabase/agent-skills --yes --global` |

Update with `npx skills update --all`.

### 5.1 Skill relevance

**Relevant to this project:** `cloudflare`, `workers-best-practices`, `durable-objects`, `wrangler`,
`firebase-basics`, `firebase-crashlytics`, `supabase`, `supabase-postgres-best-practices`.

**Not relevant, installed anyway:** `nextjs-on-cloudflare`, `sandbox-next`, `sandbox-stable`,
`sandbox-migrate-to-next`, `basin`, `k2`, `agents-sdk`, `cloudflare-one`, `cloudflare-one-migrations`,
`turnstile-spin`, `cloudflare-email-service`, and the Firebase skills for products this project
excludes: `firebase-firestore`, `firebase-auth-basics`, `firebase-data-connect`,
`firestore-rules-creation`, `firebase-security-rules-auditor`, `firebase-hosting-basics`,
`firebase-app-hosting-basics`, `firebase-remote-config-basics`, `firebase-ai-logic-basics`,
`extension-to-functions-codebase`, `xcode-project-setup`.

`firebase-auth-basics` is the actively harmful one — it teaches Firebase Auth while
`constitution.md` rule 20 mandates Supabase Auth as the only identity system. **Do not let it guide
an authentication decision.**

The install output reports failures for `PromptScript`. That agent is not in use here; the skills
installed correctly for opencode.

---

## 6. Docker is missing

`supabase start` requires it, so there is no local Supabase stack. Until it is installed:

- Develop against the hosted staging project
- Review migrations with `supabase db push --dry-run`
- Apply them with the Supabase MCP `apply_migration` tool

Installing Docker Desktop would restore full offline local development. It is optional, not blocking.

---

## 7. Secrets

| Secret | Lives in | Never in |
|---|---|---|
| Supabase service-role key | Worker secrets | apps, git |
| Firebase service-account key | Worker secrets | apps, git |
| Worker → Durable Object shared secret | Worker secrets | apps |
| Database webhook secret | Supabase + Worker secrets | apps |
| Android SQLCipher key | Android Keystore | app bundle, git |
| Supabase URL + anon key | apps (public by design, RLS-protected) | n/a |

`.env` files must be gitignored before the first commit that could contain one.