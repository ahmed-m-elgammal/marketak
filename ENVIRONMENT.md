# Environment

Everything needed to run a command: accounts, regions, versions, MCP setup, and the gotchas that
cost time if you hit them cold.

---

## 1. Accounts

| Service | Account | Identifier |
|---|---|---|
| Supabase | `ahmedmelgammal6@gmail.com` | project `Marketak` — **not yet created** |
| Cloudflare | `ahmedmelgammal6@gmail.com` | `8ae79d52c8b84a170bcb5c4c0485f34c` |
| Firebase | `ahmedmelgammal6@gmail.com` | project — **not yet created** |

---

## 2. Infrastructure choices

| Thing | Value | Why |
|---|---|---|
| Supabase project name | `Marketak` | Display name **Marketak / ماركتك** |
| Supabase region | `eu-central-1` (Frankfurt) | ADR 10. ~100–130 ms from Egypt; accepted against a 900 ms p95 target |
| R2 buckets | `Marketak-public`, `Marketak-private` | Prefixed to avoid collisions across projects |
| Firebase products used | FCM, Crashlytics, Analytics | Auth, Firestore, Storage, Functions, Hosting, Remote Config are all **excluded by design** |
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

### 4.3 Gotcha: `wrangler login` is not Cloudflare MCP auth

They are separate OAuth clients. `wrangler whoami` succeeding does **not** mean the MCP servers are
authenticated. Each needs `opencode mcp auth <name>`.

### 4.4 Re-authenticating

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