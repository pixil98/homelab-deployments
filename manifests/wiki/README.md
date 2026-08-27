# Wiki

Wiki.js 2 at `wiki.${cluster_domain}`, on a CloudNativePG cluster like every
other Postgres app in the homelab. Pages and uploaded assets are stored in the
database, so there is no PVC here and barman WAL archiving is the whole backup
story.

Access is driven by the same authentik groups as Mapper. authentik puts the
user's group names in the `groups` claim, Wiki.js maps each one to a Wiki.js
group of the same name, and each group's page rules decide which paths it can
read. A campaign lives under its own path prefix, so campaigns cannot see each
other. One shared section, `handbook/`, is readable by every campaign.

## The one awkward part

Wiki.js takes only database and transport settings from the environment.
Everything else — the OIDC strategy, groups, page rules — lives in the database
and is applied over GraphQL, not through these manifests. So the deployment is
declarative but its configuration is not; treat the bootstrap below as part of
the install, and keep the campaign service as the only thing that writes
groups and page rules afterwards.

## Permission model

Isolation comes from no group having a global read rule. Each campaign group
gets exactly one allow rule scoped to its own path prefix, and the base group
carries the shared handbook:

| authentik group         | Wiki.js group           | Page rule                                  |
|-------------------------|-------------------------|--------------------------------------------|
| `mapper`                | `mapper`                | allow `read` where path starts `handbook/` |
| `mapper-<slug>-mapper`  | `mapper-<slug>-mapper`  | allow `read` where path starts `<slug>/`  |
| `mapper-<slug>-officer` | `mapper-<slug>-officer` | allow `read,write,manage` on `<slug>/`    |
| `mapper-admin`          | `mapper-admin`          | everything                                |

Note the admin row: it is a normal group named `mapper-admin`, **not** the
built-in `Administrators` group. Group sync reconciles an OIDC user's groups to
exactly the claim on every login, and `Administrators` never appears in the
claim, so mapping to it would strip the user's admin rights on their next
login. Give `mapper-admin` the `manage:system` permission instead.

Leave the built-in **Guests** group with no read rule, otherwise anonymous
visitors can read the whole wiki. The built-in **Users** group is likewise
where an accidental global read rule would come from — check it after install.

`mapper` is the base group every campaign group descends from; the authentik
app binding uses it, so any campaign member can log in. It is also the only
group with content of its own — the handbook — and that is why both scope
mappings call `all_groups()` rather than listing direct memberships. A user in
`mapper-<slug>-officer` is not *directly* in `mapper`; only walking ancestors
puts it in their claim. authentik's own default mapping uses
`request.user.groups.all()`, which is direct-only and would silently drop it,
leaving the handbook invisible to everyone but admins.

## Content layout

```
handbook/     shared reference, read-only, maintained by us
<slug>/       one per campaign, private to that campaign's groups
templates/    source for seeding; no group has a rule granting it
```

Seeded pages fork the moment they are copied — improve a guide six months later
and existing campaigns never see it. So the split is by whether a page is meant
to be edited: working documents a campaign fills in (charts, lists, meeting
notes) get copied into `<slug>/` at provisioning time; reference material that
should stay canonical lives in `handbook/` and is never copied. Every campaign
reads the same handbook page, and improving it improves it for all of them.

## Bootstrap (one-time, after first deploy)

1. Visit `https://wiki.<domain>/` and complete the setup wizard. This creates
   the local administrator account — keep it, it is the only way back in if
   OIDC breaks.

2. Add the OpenID Connect strategy. It **must** be created with the key
   `a19a8034-8514-4578-af66-dc085d2334d1`, because the authentik provider
   pins the callback URL that this key produces:

   ```
   https://wiki.<domain>/login/a19a8034-8514-4578-af66-dc085d2334d1/callback
   ```

   The UI generates a random key instead, so create it over GraphQL at
   `/graphql` with the admin's JWT, using `authentication { updateStrategies }`
   and passing the key explicitly. Settings that matter:

   - Client ID / Secret: from `apps.auth.applications.wiki` in `secrets.json`
   - Issuer: `https://auth.<domain>/application/o/wiki/`
   - Scope: `openid profile email groups` — `groups` is required, Wiki.js reads
     the claim off the userinfo endpoint
   - **Map Groups**: on, Groups Claim: `groups`
   - Assign to group: leave empty, so users only ever hold their authentik
     groups

3. Confirm Guests and Users have no read rule, then log in through authentik.

All three steps are scriptable — nothing here requires the UI. `POST /finalize`
takes `adminEmail`, `adminPassword`, `siteUrl` and `telemetry`; from there
`authentication { login(strategy: "local") }` returns a JWT that authorises
`setApiState`, `updateStrategies` and `createApiKey`. The install is only
non-declarative, not manual.

## How group sync actually behaves

From `server/modules/authentication/oidc/authentication.js`:

```js
const expectedGroups = Object.values(WIKI.auth.groups).filter(g => groups.includes(g.name)).map(g => g.id)
```

It walks Wiki.js's own groups and keeps the ones whose name appears in the
claim, then relates what is missing and unrelates everything else. Three
consequences worth designing around:

- A claim value with no matching **Wiki.js** group is dropped silently — not
  auto-created, and nothing is logged. Creating the Wiki.js group is step 1 of
  provisioning for that reason.
- Sync is a full reconcile, so any group not in the claim is removed. Anything
  assigned by hand to an OIDC user will not survive their next login.
- It self-heals: a user who logged in before their group existed picks it up on
  their next login, so a late group creation is recoverable.

The reconcile only runs for logins through this strategy, so the local
administrator account from the setup wizard is untouched by it.

## Provisioning a campaign from the service

Everything is the GraphQL endpoint at `https://wiki.<domain>/graphql`.

**Credentials.** Turn the API on with `authentication { setApiState(enabled:
true) }` — there is no UI-only step here — then mint a key for the service:

```graphql
mutation {
  authentication {
    createApiKey(name: "campaign-service", expiration: "1y", fullAccess: true) {
      key
      responseResult { succeeded message }
    }
  }
}
```

The key goes back in `Authorization: Bearer <key>` and is shown once. `group:
Int` scopes a non-full-access key to a single group's permissions; the group
mutations below need `manage:groups` or `manage:system` either way. Keys carry
an expiry, so the service should fail loudly on a 401 rather than treat it as
"no groups yet".

1. **Groups** — `groups { create(name: "mapper-<slug>-officer") }`, which takes
   a name and nothing else, and returns the new `group { id }`. Do this before
   anyone in the campaign logs in; until it exists their claim entry is dropped
   silently, though a later login picks it up once it does.

   The name has to match the authentik group's name exactly, since that is all
   Wiki.js matches on. On the authentik side the campaign and role live in the
   group's `attributes` (see `manifests/authentik/mapper_epic.yaml`) and the
   name is only a label — so the service should build both from the same
   record rather than parsing one out of the other.

2. **Page rules** — `groups { update(...) }`. Every argument is non-null
   (`name`, `redirectOnLogin`, `permissions`, `pageRules`), so this is a full
   replace rather than a patch: read the group with `groups { single(id:) }`
   and send the complete merged object back, or you will silently blank its
   other rules.

   ```graphql
   mutation {
     groups {
       update(
         id: 5
         name: "mapper-epic-officer"
         redirectOnLogin: "/"
         permissions: ["read:pages", "write:pages", "manage:pages", "read:assets", "write:assets"]
         pageRules: [{
           id: "epic-content"
           deny: false
           match: START
           path: "epic/"
           roles: ["read:pages", "write:pages", "manage:pages"]
           locales: []
         }]
       ) { responseResult { succeeded message } }
     }
   }
   ```

   `permissions` is the global capability list and `pageRules` scopes where
   those capabilities apply — a group needs the permission globally *and* a
   rule granting it on the path. `match` accepts `START`, `EXACT`, `END`,
   `REGEX` or `TAG`; `START` is the prefix match campaigns want. Rule `id` is
   any string you choose, so keep it stable per campaign to make updates
   idempotent.

3. **Seed from template** — copy only the working documents. List `templates/`
   with `pages { list(...) }`, fetch each page with `pages { single(id:) }` for
   its `content`, and recreate them with `pages { create(...) }` under
   `<slug>/`. Pass the template's `editor` and `contentType` through unchanged
   so markdown pages do not come back as HTML.

   `handbook/` is not seeded and not copied — the rule on the base `mapper`
   group already grants it, so a new campaign can read it the moment its
   members can log in.

## Notes

Wiki.js 2 is in maintenance mode upstream — 2.5.x still gets fixes but v3 has
no release date. This was a deliberate trade for staying on Postgres rather
than running MariaDB for BookStack.
