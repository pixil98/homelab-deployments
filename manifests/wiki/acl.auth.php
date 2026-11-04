# acl.auth.php
# <?php exit()?>
# Don't modify the lines above
#
# The rules in this file are owned by git (manifests/wiki/acl.auth.php) and
# rewritten on every start by prepare-storage.sh. Any other rule in the live
# file, such as a campaign's, is carried over untouched. See README.md.
#
# none 0, read 1, edit 2, create 4, upload 8, delete 16
#
# Group names are stored URL-encoded, hyphens included: a rule for
# mapper-epic-officer is written @mapper%2depic%2dofficer. The ACL manager and
# the plugin.acl.addAcl API encode for you; only hand-written rules need it.
#
# Nobody can read anything unless a rule grants it. With this as the default, a
# page in another campaign answers "permission denied" exactly like a page in a
# namespace that does not exist, so guessing slugs reveals nothing.
*               @ALL       0
# The landing page and the shared handbook, for everyone who can log in.
start           @mapper    1
handbook:*      @mapper    1
# DokuWiki's markup reference, which the editor links to. The image refreshes
# this page on every start.
wiki:syntax     @mapper    1
