# campaign-manager

The campaign service (`CAMPAIGN_SERVICE.md` at the root of this branch), from
github.com/pixil98/campaign-manager, at `campaigns.${cluster_domain}`. It
creates campaigns and adds or invites people into them, across authentik and
the wiki.

## What it is made of

| Piece | Where |
|-------|-------|
| The provider callers' tokens come from, and its `campaigns` scope | `manifests/authentik/campaign_manager_provider.yaml` |
| Its authentik service account, role and API token | `manifests/authentik/campaign_manager_account.yaml` |
| The API token's key | `apps.campaignManager.authentikToken` in `secrets.json`, mounted from `campaign-manager-authentik` |
| Its wiki account and API token | made by `manifests/wiki/prepare-storage.sh`, which writes the token into `campaign-manager-wiki-token` here |
| Permission for the wiki to write that Secret | `wiki_token_rbac.yaml` |
| Its settings | `config.json`, whose keys are described in the repository's README |

Both tokens are read from mounted files, so neither is in the config.
Reloader restarts the service when either Secret changes.

Invitations use the generic `invitation-enrollment` flow for now. Once the
campaign enrollment flow exists, change `invitation_flow` in `config.json`.
`send_invitation_email` stays off until ugre can send mail; meanwhile the
link is returned to the inviter to pass on.

## Calling it

With `mpr`, the service's command line (released from the campaign-manager
repository):

```sh
mpr login --server https://campaigns.<domain>
mpr whoami
mpr campaign create <slug> --name "<real name>"
mpr invite <slug> <email> --role mapper
```

`mpr login` uses authentik's device code login: it prints a link, the person
logs in there, and mpr keeps a refresh token for 30 days. It reads the issuer
and client id from the service's `GET /auth`. The device page needs the
brand's device code flow, which the provider blueprint sets.

The service asks authentik's userinfo endpoint about every token, so a revoked
token, or a deactivated user's, stops working at once, and roles are read
fresh on each request. Access tokens last five minutes, which is only how often
mpr refreshes them; `access_token_validity` in the provider blueprint can be
raised without letting anyone keep access they have lost.

## Starting it up

Nothing here is ready until three things exist, and nothing has to happen in
any particular order:

- **The image.** `ghcr.io/pixil98/campaign-manager:main` is published by the
  repository's CI. Until then the pod cannot pull, and this Kustomization is
  not ready.
- **The authentik token's key** in `flux-secrets`. The blueprint skips the
  token while the key is empty, so authentik never holds a token with an
  empty key.
- **The wiki token Secret**, which the wiki writes when it starts. If the wiki
  started before this namespace existed, restart it once:
  `kubectl -n wiki rollout restart deploy/dokuwiki`.
