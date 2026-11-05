# Wiki

DokuWiki at `wiki.${cluster_domain}`. There is no database: pages, media,
accounts, ACL rules and plugins are plain files on one volume
(`dokuwiki-data`), backed up nightly by VolSync the same way as Mapper's.

Access is driven by the same authentik groups as Mapper. authentik puts the
user's group names in the `wiki_groups` claim, DokuWiki replaces the account's
groups with that list, and ACL rules on each namespace decide who can read it.
A campaign lives in its own namespace, so campaigns cannot see each other. One
shared namespace, `handbook:`, is readable by every campaign.

## Where things live

| What | Where | Changed by |
|------|-------|------------|
| Settings (login, privacy, access defaults) | `dokuwiki_config.yaml`, mounted as `conf/local.protected.php` and `conf/plugins.protected.php` | git only; the admin UI shows them as locked |
| Plugins (`oauth`, `oauthgeneric`) | pinned `tag@commit` in `prepare-storage.sh` | Renovate |
| Base ACL rules | `acl.auth.php` here | git; rewritten into the volume on every start |
| Campaign ACL rules | `conf/acl.auth.php` on the volume | the campaign service, or the ACL manager |
| Accounts | `conf/users.auth.php` on the volume | the oauth plugin, from authentik, at every login |
| campaign-manager's account | the same file | `prepare-storage.sh`, once |
| campaign-manager's API token | minted on the volume, delivered as the Secret `campaign-manager/campaign-manager-wiki-token` | `prepare-storage.sh`, on every start |
| Pages and media | `data/` on the volume | people |

`prepare-storage.sh` runs as an init container before every start. It installs
the pinned plugins, rewrites the base ACL rules while carrying every other rule
over, and creates the empty user file on first start. Editing it or
`acl.auth.php` changes the generated ConfigMap's name, which rolls the pod.

## Permission model

Nothing is readable unless a rule grants it (`* @ALL 0`). Each campaign gets
rules on its own namespace only, and the base group carries the handbook:

| authentik group         | ACL rule, as stored                              | Grants                              |
|-------------------------|--------------------------------------------------|-------------------------------------|
| `mapper`                | `handbook:* @mapper 1`, `start @mapper 1`        | read the handbook and landing page  |
| `mapper-<slug>-mapper`  | `<slug>:* @mapper%2d<slug>%2dmapper 1`           | read the campaign                   |
| `mapper-<slug>-officer` | `<slug>:* @mapper%2d<slug>%2dofficer 16`         | read, edit, create, upload, delete  |
| `mapper-admin`          | `superuser` setting, no rule                     | everything, including the admin UI  |

DokuWiki stores group names in ACL rules URL-encoded, hyphens included, hence
the `%2d`. The ACL manager and the API encode for you; only a rule written by
hand needs it.

Because a campaign's existence is itself sensitive (see
`manifests/authentik/README.md`), the rules are backed by settings that keep
other campaigns out of sight, not just out of reach. These were checked as a
member of one campaign, in a local run of this image and config, before
switching over:

- Search, title lookup, recent changes and the page index list only readable
  pages. The index needs `sneaky_index`, which is set; without it, every
  namespace name shows up there.
- A page in another campaign and a page in a namespace that does not exist both
  answer "permission denied", so guessing slugs reveals nothing.
- `conf/` and `data/` are not reachable over HTTP; media goes through
  DokuWiki's ACL check like pages do.

The landing page `start` is readable by everyone, so do not link campaigns from
it — a link shows the slug even to people who cannot follow it.

## How group sync actually behaves

From the oauth plugin's `OAuthManager.php`:

- The first login creates the account, matched on email afterwards, so the
  `email` claim is required. There is no sign-up, password or profile page.
- Each time the plugin fetches the claims it replaces the account's groups with
  `wiki_groups`, keeping only DokuWiki's own `user` and `generic` groups, which
  no rule mentions. It fetches them at login, and again whenever a session older
  than `auth_security_timeout` (15 minutes) is used, using the refresh token
  that `offline_access` grants. Someone removed from a campaign in authentik
  therefore loses it here within about 15 minutes, without logging in again. If
  authentik refuses the refresh, the session is logged out.
- Nothing has to be created on the wiki side for a group. DokuWiki groups are
  just names on the account and in the rules, so a claim value with no rule
  grants nothing, and a rule added before anyone logs in simply waits.

## Content layout

```
handbook:     shared reference, read-only, maintained by us
<slug>:       one per campaign, private to that campaign's groups
templates:    source for seeding; no rule grants it, so only admins see it
```

Seeded pages fork the moment they are copied — improve a guide six months later
and existing campaigns never see it. So the split is by whether a page is meant
to be edited: working documents a campaign fills in (charts, lists, meeting
notes) get copied into `<slug>:` at provisioning time; reference material that
should stay canonical lives in `handbook:` and is never copied.

## Provisioning a campaign from the service

The wiki's part of it. `CAMPAIGN_SERVICE.md` at the root of this branch covers
the whole service, including authentik and inviting people.

Everything goes through DokuWiki's JSON-RPC API at
`https://wiki.<domain>/lib/exe/jsonrpc.php`.

1. **Rules** — `plugin.acl.addAcl` with scope `<slug>:*`, once for
   `@mapper-<slug>-mapper` at level 1 and once for `@mapper-<slug>-officer` at
   level 16. It adds or updates, so repeating it is safe, and it does the name
   encoding itself.
2. **Seed from template** — `core.listPages` on `templates`, then
   `core.getPage` and `core.savePage` for each working document under
   `<slug>:`.

The API is on for campaign-manager alone (`remote` and `remoteuser` in
`dokuwiki_config.yaml`); everyone else gets 401. Its account is a local one,
`campaign-manager`, with no usable password and the `campaign-manager` group,
which is a superuser so it can add ACL rules. It signs in with an API token,
which DokuWiki checks before the authentik login runs. No authentik user can
carry that group, since the `wiki_groups` claim only holds mapper groups.

The token is signed with a salt on the volume, so it cannot be made outside
the wiki. `prepare-storage.sh` mints it on every start (DokuWiki hands back
the stored one while it is valid) and writes it into the Secret
`campaign-manager/campaign-manager-wiki-token`. It does this with a service
account token mounted into the init container alone, so the PHP app itself
has no Kubernetes credentials. If that fails, for example because
campaign-manager is not deployed yet, the wiki starts anyway with a warning.
Restarting the wiki publishes the token again.

## Break-glass

There is no local administrator. `mapper-admin` in authentik is the superuser,
and if authentik is unreachable nobody can log in. The way in is then the files
themselves: pages are plain text under `/storage/data/pages/<namespace>/`, and
`kubectl -n wiki exec deploy/dokuwiki` reaches them. Settings are read-only
mounts, so changes to them go through git.

## Upgrades

The image tracks `stable` by digest rather than a release tag. DokuWiki's tags
carry a hotfix letter (`2026-07-14c`) that Renovate's versioning cannot order,
so a tag pin would miss hotfixes; with the digest, every release and rebuild
arrives as an image digest PR. The image refreshes DokuWiki's bundled files
on start, so an upgrade needs nothing else.

Plugin pins are tracked by a custom manager in `renovate.json` on the
production branch, which is where Renovate reads its configuration for every
branch.
