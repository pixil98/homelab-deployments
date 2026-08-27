# authentik

Blueprints for the apps this cluster fronts. authentik itself comes from the
core profile (`20_platform/auth`); everything here is configuration applied to
it as blueprint secrets, picked up by the `goauthentik.io/blueprint` label.

authentik is the identity provider **and** the membership record: which
campaigns a person belongs to, and in what role, is stored here and nowhere
else. Mapper learns it from the `groups` scope at login; Wiki.js cannot
request a custom scope, so it learns it from `profile` (see below).

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

## Attributes are the record, names are labels

Campaign and role live in each group's `attributes`:

```yaml
attributes:
  campaign: epic
  role: officer
```

The group's *name* is not parsed for them. It exists because Wiki.js matches
claim strings against its own group names and has no other way to identify a
group — so the name has to be stable and has to match, but it carries no
meaning the code depends on. Keeping the two separate means a slug like
`trader-joes-local-1` cannot break anything, which name parsing would.

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
because Wiki.js cannot read a structured claim. Both are the same underlying
fact.

It sits on the `profile` scope rather than `groups`. Wiki.js 2.5 builds its
passport strategy with no scope option and only ever requests
`openid profile email`, so a mapping under a custom scope never runs — the
one here did nothing until it was moved. The claim is named `wiki_groups`
rather than `groups` because authentik's stock `profile` mapping already
emits `groups`, and claims from every mapping on a scope are merged: two
mappings writing the same key would leave the winner down to processing
order. Wiki.js is pointed at `wiki_groups` through its `groupsClaim`
setting, so the stock direct-only claim is ignored.

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

Either way the same slug has to be used for the Wiki.js groups and the wiki
path prefix — see `manifests/wiki/README.md`.

## Note on slugs

The slug appears in group names, wiki paths and application launch URLs. For a
workplace that has not gone public, the fact that a campaign exists is itself
sensitive, so a slug naming the employer leaks it to anyone who can see any of
those surfaces. Opaque slugs with the real name kept as a group attribute cost
nothing to adopt now and are painful later, since renaming reassigns members.
