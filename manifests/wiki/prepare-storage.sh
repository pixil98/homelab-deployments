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
