# Campaign service

Not built yet. This records what it has to do to create a campaign and to
invite a person into one, what it needs before it can, and how to do the same
by hand until then. Status as of 2026-11-04.

The service is the only thing meant to write campaign state once it exists.
Until then, everything below is done by hand (see the end of this file).

## What a campaign is

A campaign has no record of its own. It is a slug that three systems agree on:

| System | Per-campaign state | Per-person state |
|--------|--------------------|------------------|
| authentik | two groups, `mapper-<slug>-mapper` and `mapper-<slug>-officer`, both under `mapper`, with `campaign` and `role` attributes | membership in one of those groups — the only record of who is in a campaign |
| Mapper | none: it reads campaign and role from the group names in the `groups` claim, using the patterns in `manifests/mapper/mapper_server_env.yaml` | none, read from the claim at each login |
| Wiki | two ACL rules on the `<slug>:` namespace, plus the working pages copied from `templates:` | none: the account and its groups come from authentik at login, then every 15 minutes |

Constraints that follow from that:

- **The slug is permanent and opaque.** It appears in group names, wiki paths
  and URLs, and a campaign's existence is itself sensitive, so it must not
  name the employer (see `manifests/authentik/README.md`). Keep it to
  lowercase letters, digits and single hyphens: that survives both DokuWiki's
  page-name cleaning and Mapper's name patterns unchanged. Renaming a group
  reassigns its members, so a slug is never changed or reused.
- **Group names are an interface.** Mapper parses them with
  `mapper-{campaign}-officer` and `mapper-{campaign}-mapper`, and the wiki's
  ACL rules name them as plain strings. The `campaign` and `role` attributes
  are the record; the names still have to match exactly.
- **authentik is the only membership record.** The service never writes
  membership into Mapper or the wiki; both pick it up from the login claim.
- **One writer per object.** Once the service exists, it owns the campaign
  groups and the campaign ACL rules. Any campaign still declared in git (a
  blueprint like `manifests/authentik/mapper_epic.yaml`, or rules in
  `manifests/wiki/acl.auth.php`) moves out of git when the service takes it
  over. Removing a blueprint does not delete the groups it created.

## Creating a campaign

Input: the slug, the real name (kept as a group attribute, never in the slug),
and the first officer's email. Every step is find-or-create, so a failed run
can simply be repeated.

1. **Groups (authentik).** Create `mapper-<slug>-mapper` and
   `mapper-<slug>-officer` with `POST /api/v3/core/groups/`, setting
   `parents` to the `mapper` group's pk and `attributes` to
   `{"campaign": "<slug>", "role": "mapper" | "officer", "name": "<real name>"}`.
   Look them up by name first. The parent is what lets members log in to
   either app, since both apps are bound to `mapper` alone.
2. **Wiki access.** Call `plugin.acl.addAcl` on the wiki's JSON-RPC API
   (`/lib/exe/jsonrpc.php`) twice, both for scope `<slug>:*`:
   `@mapper-<slug>-mapper` at level 1 (read) and `@mapper-<slug>-officer` at
   level 16 (everything up to delete). It adds or updates, and it URL-encodes
   the group names itself (`-` is stored as `%2d`).
3. **Wiki pages.** `core.listPages` on `templates`, then for each working
   document `core.getPage` and `core.savePage` into `<slug>:`. Skip pages that
   already exist, so a repeated run does not overwrite edits. Never copy
   `handbook:` — every campaign reads the one shared copy.
4. **First officer.** Invite them as below, with role `officer`.

Do the wiki rules before the first invite, so the first login already works.
DokuWiki does not need the groups to exist first: its rules are just names.

## Inviting a person

Input: slug, role (`mapper` or `officer`), email, and optionally a suggested
username and display name.

1. **Existing account?** `GET /api/v3/core/users/?email=<email>`. If one exists,
   add it to `mapper-<slug>-<role>` with
   `POST /api/v3/core/groups/<pk>/add_user/` and stop. The wiki picks this up
   within 15 minutes; Mapper at the person's next login.
2. **Otherwise, create an invitation** with
   `POST /api/v3/stages/invitation/invitations/`:
   - `flow`: the `invitation-enrollment` flow (flux-core
     `20_platform/auth/authentik_enrollment_blueprint.yaml`)
   - `single_use: true`, and an `expires` a few days out
   - `fixed_data`:
     ```json
     {
       "email": "<email>",
       "groups": ["mapper-<slug>-<role>"],
       "prefill": {"username": "<suggested>", "name": "<suggested>"}
     }
     ```
   `groups` holds group names; the flow's `enrollment-map-invitation-groups`
   policy turns them into memberships and warns about any it cannot find. The
   base `mapper` group comes along through the parent. The email comes only
   from the invitation, so it always matches the mailbox the invite went to.
   `prefill` depends on the `enrollment-prefill-from-invitation` policy, which
   is an uncommitted change in flux-core as of this writing.
3. **Send it** with
   `POST /api/v3/stages/invitation/invitations/<pk>/send_email/` and
   `{"email_addresses": ["<email>"]}`. authentik builds the link from the
   request's host, so this call has to go to `https://auth.<domain>`, not to
   authentik's in-cluster Service, or the email carries an internal URL. The
   subject is "You have been invited to auth.<domain>", which names no
   campaign.

   authentik on ugre cannot send mail yet (see `MAIL.md`). Until it can, hand
   out the link directly:
   `https://auth.<domain>/if/flow/invitation-enrollment/?itoken=<invitation pk>`.

Redeeming the invite asks for a username, display name and password, consumes
the invitation, creates the account in the invited group, and logs the person
in.

**Watch for the Google and Discord buttons.** Those sources enroll anyone who
signs in through them, with no groups. An invitee who uses one instead of the
link ends up with an account but no campaign. Running the invite again then
takes step 1 and adds the group. The unused invitation should be deleted at
that point, since the enrollment flow always creates a new user.

## What the service needs first

- **An authentik identity.** A service account with an API token and a role
  that can read users, create groups and change their membership, and create,
  send and delete invitations, and nothing else. All of it can be declared in
  a blueprint, with the token key in `secrets.json`.
- **The wiki API, switched on.** Set `remote = 1` and `remoteuser` in
  `manifests/wiki/dokuwiki_config.yaml`. `plugin.acl.addAcl` only works for
  a superuser, so the service's wiki account has to be in `superuser` too.
  DokuWiki checks an `Authorization: Bearer <token>` header before the
  authentik login runs, so the service needs no password, but it does need a
  local account in `users.auth.php` for its groups, and a token. Tokens are
  normally minted on the profile page, which is disabled here, so it has to be
  minted once from inside the pod (`dokuwiki\JWT::fromUser`) and stored as a
  Secret. Tokens are signed with the wiki's cookie salt, which lives on the
  volume.
- **Email on ugre**, for `send_email`, as planned in `MAIL.md`.

## Not decided yet

- **Who may use it.** Admins only, or officers inviting into their own
  campaign? If officers, the service has to check the caller's
  `mapper-<slug>-officer` membership itself.
- **Where it runs**, and whether it lives inside Mapper.
- **Whether Mapper keeps per-campaign data of its own** that needs creating.
  Nothing in this repo shows that it does.
- **Removing a person and changing roles.** Remove the group membership in
  authentik; the wiki follows within 15 minutes and Mapper at the next login.
  Outstanding invitations for that person should be deleted too.
- **Retiring a campaign:** remove its groups and ACL rules, archive the
  namespace, and never reuse the slug.
- **Open enrollment through Google and Discord**, which creates accounts for
  anyone. They can reach nothing without a campaign group, but the accounts
  exist.

## Today, by hand

1. Copy `manifests/authentik/mapper_epic.yaml` to `mapper_<slug>.yaml`.
   Change the Secret and blueprint names, both group names and both
   `campaign` attributes, then add it to `manifests/authentik/kustomization.yaml`.
2. Add the two rules to `manifests/wiki/acl.auth.php` with the names encoded,
   e.g. `<slug>:* @mapper%2d<slug>%2dmapper 1` and
   `<slug>:* @mapper%2d<slug>%2dofficer 16`. Committing them rolls the wiki pod,
   which writes them. Alternatively, add them in the wiki's ACL manager as
   `mapper-admin`, in which case they live only on the volume.
3. Invite people from the authentik admin UI (Directory → Invitations), with
   the `invitation-enrollment` flow and the `fixed_data` shown above. Or add
   existing accounts to the group directly.
4. An officer creates `<slug>:start` and copies working documents from
   `templates:`. Don't link the campaign from the root `start` page: everyone
   can read it.
