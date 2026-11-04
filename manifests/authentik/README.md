# authentik

Blueprints for the apps this cluster fronts. authentik itself comes from the
core profile (`20_platform/auth`); everything here is configuration applied to
it as blueprint secrets, picked up by the `goauthentik.io/blueprint` label.

authentik is the identity provider **and** the membership record: which
campaigns a person belongs to, and in what role, is stored here and nowhere
else. Mapper and the wiki each learn it from their own `groups` scope at
login (see below).

## Group model

```
mapper                      base group — everyone who can use the platform
├── mapper-admin            cluster-wide admin (no campaign)
├── mapper-<slug>-mapper    campaign member
└── mapper-<slug>-officer   campaign organizing committee
```

Every campaign group parents to `mapper`, so the single app binding on `mapper`
in `mapper_provider.yaml` gates both applications — authentik counts members of
a child group as members of the parent, so there are no per-campaign bindings
to maintain.

## Attributes are the record, names are an interface

Campaign and role live in each group's `attributes`:

```yaml
attributes:
  campaign: epic
  role: officer
```

The attributes are the record, and the `campaigns` claim is built from them.
The group's *name* still matters, though. The wiki's ACL rules name groups as
plain strings and have no other way to identify one. Mapper, as configured in
`manifests/mapper/mapper_server_env.yaml`, reads campaign and role out of the
names with the patterns `mapper-{campaign}-mapper` and
`mapper-{campaign}-officer` rather than from the `campaigns` claim. So the
name has to be stable and has to follow those patterns exactly.

Renaming a group reassigns every member, so treat names as immutable once a
campaign has people in it.

## Claim shape

`Mapper - groups` (in `mapper_provider.yaml`) emits:

```json
{
  "groups": ["mapper", "mapper-epic-officer"],
  "campaigns": { "epic": ["officer"] },
  "mapper_admin": false
}
```

`Wiki - groups` (in `wiki_provider.yaml`) emits a flat `wiki_groups` list,
because DokuWiki's ACL rules match plain group names. Both are the same
underlying fact.

The claim is named `wiki_groups` rather than `groups` because the wiki also
requests `profile`, whose stock mapping already emits a direct-only `groups`,
and claims from every granted scope are merged: two mappings writing the same
key would leave the winner down to processing order. DokuWiki is pointed at
`wiki_groups` through the oauthgeneric `json-grps` setting, so the stock claim
is ignored.

The wiki also requests `offline_access` for a refresh token, which it uses to
re-read `wiki_groups` every 15 minutes of a session. Removing someone from a
campaign here therefore reaches the wiki without waiting for a fresh login.

Two things the expressions do deliberately:

- **`all_groups()`, not `groups.all()`.** authentik's default mapping lists
  direct memberships only. A user in `mapper-epic-officer` is not directly in
  `mapper`, so the base group would be missing from their claim — and the
  wiki's shared `handbook/` section is granted through exactly that group.
  `all_groups()` walks ancestors, matching how the app binding already
  resolves.
- **Filtered to `mapper` groups.** Unfiltered, the claim grows with every
  campaign a person joins and every unrelated app's groups ride along. An admin
  account accumulates all of them, in every ID token, with
  `include_claims_in_id_token: true` set. Bounding it now avoids a header-size
  failure later.

## Adding a campaign

Today: copy `mapper_epic.yaml`, change the slug and the two `attributes`
blocks. Once the campaign service exists it creates the groups over the
authentik API instead, and that file stays as the reference for the shape.

Either way the same slug has to be used for the wiki namespace and its ACL
rules. `CAMPAIGN_SERVICE.md` at the root of this branch lists every step
across authentik, Mapper and the wiki, for creating a campaign and for
inviting someone into one.

## Note on slugs

The slug appears in group names, wiki paths and application launch URLs. For a
workplace that has not gone public, the fact that a campaign exists is itself
sensitive, so a slug naming the employer leaks it to anyone who can see any of
those surfaces. Opaque slugs with the real name kept as a group attribute cost
nothing to adopt now and are painful later, since renaming reassigns members.
