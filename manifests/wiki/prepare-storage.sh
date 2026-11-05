#!/bin/bash
# Runs as the init container, against the storage volume, before DokuWiki
# starts. Every step is safe to repeat on every start.
#
# Flux substitutes dollar-brace variables in everything under manifests/, this
# file included, so variables here are only ever written as $name.
set -euo pipefail

storage=/storage
conf=$storage/conf
plugins=$storage/lib/plugins

# The image's own storage setup, which the app container runs again when it
# starts. Running it here first gives a fresh volume DokuWiki's data
# directories, which minting the API token below needs.
/dokuwiki-storagesetup.sh > /dev/null
mkdir -p "$conf" "$plugins"

# The image keeps conf/ on the volume without the .htaccess that ships with
# DokuWiki. Its PHP files exit before printing anything, but nothing else in
# there needs to be reachable over HTTP either.
printf '%s\n' 'Require all denied' > "$conf/.htaccess"

# Installs a plugin from GitHub at a pinned tag@commit. Renovate keeps the pins
# current (see renovate.json on the production branch); the tag is for people
# and Renovate, the commit is what is actually fetched.
install_plugin() {
  local name=$1 repo=$2 pin=$3
  local commit dir tmp
  commit=$(echo "$pin" | cut -d@ -f2)
  dir=$plugins/$name

  if [ "$(cat "$dir/.pinned" 2>/dev/null)" = "$pin" ]; then
    echo "$name $pin already installed"
    return
  fi

  tmp=$(mktemp -d)
  curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/$repo/archive/$commit.tar.gz" |
    tar -xz --strip-components=1 -C "$tmp"
  echo "$pin" > "$tmp/.pinned"
  rm -rf "$dir"
  mv "$tmp" "$dir"
  echo "installed $name $pin"
}

install_plugin oauth cosmocode/dokuwiki-plugin-oauth 2026-10-29@c5070fd35efc712b782a45f07fbc27efbaa75a2b
install_plugin oauthgeneric cosmocode/dokuwiki-plugin-oauthgeneric 2025-10-02@b5a56539fa613753e7163ae291ba7b759033040f

# The rules in the managed acl.auth.php replace whatever the live file has for
# the same scope and subject. Every other live rule, such as the per-campaign
# rules the campaign service adds, is kept as it is.
managed=/config/acl.auth.php
acl=$conf/acl.auth.php
next=$(mktemp -p "$conf")
cp "$managed" "$next"
if [ -f "$acl" ]; then
  awk 'NR == FNR { if ($1 !~ /^#/ && NF) owned[$1 " " $2] = 1; next }
       $1 !~ /^#/ && NF && !(($1 " " $2) in owned)' "$managed" "$acl" >> "$next"
fi
mv "$next" "$acl"
echo "applied managed ACL rules"

# The oauth plugin keeps its accounts in DokuWiki's plain user file and refuses
# to authenticate anyone if the file is missing.
users=$conf/users.auth.php
if [ ! -f "$users" ]; then
  printf '%s\n' '# users.auth.php' '# <?php exit()?>' "# Don't modify the lines above" \
    '#' '# Written by the oauth plugin from authentik on each login.' > "$users"
  echo "created empty user file"
fi

# campaign-manager's wiki account. Its password field is "!", which matches no
# password: it only ever signs in with the API token below, which DokuWiki
# checks before any other login. Its group is a superuser and the only one
# allowed the API (dokuwiki_config.yaml). The address is unroutable on
# purpose; the oauth plugin matches accounts by email, so it must be one no
# authentik user has.
account=campaign-manager
if ! grep -q "^$account:" "$users"; then
  printf '%s:!:Campaign manager:%s@wiki.invalid:%s\n' "$account" "$account" "$account" >> "$users"
  echo "added the $account account"
fi

# Delivers the account's API token to campaign-manager, as the Secret
# campaign-manager/campaign-manager-wiki-token. DokuWiki hands back the stored
# token for as long as it is valid, so this is the same token every start.
# The token is signed with a salt that lives on this volume, which is why it is
# minted here rather than kept in git.
publish_token() {
  local kube=/var/run/secrets/kube-api
  local api=https://kubernetes.default.svc/api/v1/namespaces/campaign-manager/secrets
  local name=campaign-manager-wiki-token
  local token body

  token=$(php -r 'define("DOKU_INC", "/var/www/html/"); require DOKU_INC . "inc/init.php";
                  echo "\n", \dokuwiki\JWT::fromUser("campaign-manager")->getToken(), "\n";' | tail -n 1) || return 1
  case "$token" in
    eyJ*.*.*) ;;
    *) echo "minting gave no token" >&2; return 1 ;;
  esac

  body=$(printf '{"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "%s"}, "type": "Opaque", "stringData": {"token": "%s"}}' "$name" "$token")
  kube_api() {
    curl --fail --silent --show-error --output /dev/null --cacert "$kube/ca.crt" \
      -H "Authorization: Bearer $(cat "$kube/token")" -H "Content-Type: application/json" "$@"
  }
  # Replace it if it exists, otherwise create it.
  kube_api -X PUT --data "$body" "$api/$name" 2> /dev/null || kube_api -X POST --data "$body" "$api" || return 1
  echo "published the $account API token"
}

# A failure only warns: the wiki has to start whether or not campaign-manager
# is deployed yet. Restarting the wiki publishes it again.
publish_token || echo "warning: could not publish the $account API token" >&2
