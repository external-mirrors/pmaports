# Backporting from edge

## Workflow

* Merge request authors or other contributors may add a `backport-to-vYY.MM`
  label to pmaports MRs that shall be backported.

* After the MR is merged, postmarketOS team members can then backport the
  patches to the given stable branch. If you are not a team member and need
  somebody to do the backport, you can ask in
  [postmarketos-devel](https://wiki.postmarketos.org/wiki/Matrix_and_IRC).

* Use <code>git cherry-pick -x ffffffff</code> (insert commit to cherry pick
  accordingly) for every patch. The <code>-x</code> will add a <code>(cherry
  picked from commit ffffffff)</code> line to the commit message.

* If you really know what you are doing and the change is trivial or the stable
  branch is not released yet, then you can directly push the backported patch
  to the stable branch. Otherwise you *must* make a merge request against the
  stable branch with the backport. We don't want stable branches to break!

* Add a comment to the original merge request where the backport can be found
  (with a link to the merge request or backported commit hash).

## What to look out for

* Cherry picked commits shall not be squashed, then it's hard to understand
  which commits were already picked and which were not.

* Avoid cherry-picking multiple patches that touch the same pmaports in the
  wrong order.
