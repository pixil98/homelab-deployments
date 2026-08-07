# Wiki

BookStack at `wiki.${cluster_domain}`, backed by its own MariaDB (BookStack is
MySQL-only, so it does not use the cluster's CloudNativePG operator).

Access is driven by the same authentik groups as Mapper. authentik puts the
user's group names in the `groups` claim; BookStack matches each one to a role
and, on every login, syncs the user's roles to exactly that set
(`OIDC_REMOVE_FROM_GROUPS=true`). Dropping someone from `mapper-epic-officer`
in authentik therefore revokes their Epic wiki access the next time they log in.

## Permission model

Isolation comes from campaign roles holding **no** `*-view-all` system
permissions. A role with no view-all sees nothing except what an entity-level
override explicitly grants it, so campaigns cannot see each other by default —
new content is private unless a shelf/book override opens it up.

| authentik group          | BookStack role           | Grant on the campaign shelf/books |
|--------------------------|--------------------------|-----------------------------------|
| `mapper-<slug>-mapper`   | `mapper-<slug>-mapper`   | view                              |
| `mapper-<slug>-officer`  | `mapper-<slug>-officer`  | view, create, update, delete      |
| `mapper-admin`           | `Admin` (built-in)       | everything                        |

`mapper` is the base group every campaign group descends from; the authentik
app binding uses it, so any campaign member can reach the wiki. What they can
read once inside is decided entirely by the roles above.

## Bootstrap (one-time, after first deploy)

Auth is OIDC-only, so there is no password login to fall back on. Point the
built-in Admin role at the `mapper-admin` group **before** the first login —
otherwise group sync strips Admin from whoever logs in first:

```sh
kubectl -n wiki exec deploy/bookstack -- \
  s6-setuidgid abc php /app/www/artisan tinker --execute \
  "DB::table('roles')->where('display_name','Admin')->update(['external_auth_id'=>'mapper-admin']);"
```

Then log in at `https://wiki.<domain>/` as a member of `mapper-admin`. Group
sync creates the user and grants Admin.

Finally, create the campaign service's credentials: add a user with a role
holding `access-api` plus `users-manage` and `restrictions-manage-all`, and
generate an API token under its profile. API tokens can only be created through
the UI, so this step cannot be automated.

If OIDC ever breaks, `/login?prevent_auto_init=true` stops the automatic
redirect to authentik.

## Provisioning a campaign from the service

Auth header for every call: `Authorization: Token <token_id>:<token_secret>`.

1. **Roles** — `POST /api/roles`, once per campaign role. Set
   `external_auth_id` to the authentik group name rather than relying on the
   display name; BookStack lower-cases and hyphenates claim values before
   matching, and an explicit id survives a later rename.

   ```json
   { "display_name": "mapper-epic-officer",
     "external_auth_id": "mapper-epic-officer",
     "permissions": ["page-create-own", "page-update-own", "page-delete-own"] }
   ```

   Keep `*-view-all` / `*-update-all` out of this list — those would expose
   every other campaign.

2. **Container** — `POST /api/books` for the campaign's book, then
   `POST /api/shelves` with the book id if you want a shelf per campaign.

3. **Permissions** — `PUT /api/content-permissions/{contentType}/{contentId}`,
   where `contentType` is `book`, `chapter`, `page`, or `bookshelf` (not
   `shelf`). Setting `fallback_permissions.inheriting: false` with everything
   false is what makes the item private to the listed roles:

   ```json
   { "role_permissions": [
       { "role_id": 5, "view": true,  "create": false, "update": false, "delete": false },
       { "role_id": 6, "view": true,  "create": true,  "update": true,  "delete": true }
     ],
     "fallback_permissions": { "inheriting": false, "view": false, "create": false, "update": false, "delete": false } }
   ```

   An empty `role_permissions` array **clears** all existing overrides, so read
   the current permissions and send the merged result when updating rather than
   replacing.

   Shelf permissions do not cascade to books automatically — apply the override
   to each book as it is created.

4. **Seed from template** — there is no copy endpoint. Keep a template book in
   BookStack, read its structure with `GET /api/books/{id}` and each page with
   `GET /api/pages/{id}` (returns `markdown` and `html`), then recreate them
   with `POST /api/chapters` and `POST /api/pages` against the new book. Send
   `markdown` if the template was authored in markdown, otherwise pages come
   back as converted HTML and round-trip lossily.

## Backups

Both PVCs go to restic via volsync. The MariaDB backup is a volume snapshot of
a live InnoDB datadir, so a restore is crash-consistent and replays the redo
log; it is not a logical dump.
