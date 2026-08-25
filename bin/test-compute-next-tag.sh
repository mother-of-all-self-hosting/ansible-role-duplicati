#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Exercises bin/compute-next-tag.sh against throwaway git repositories.
#
# Usage: bin/test-compute-next-tag.sh
#
# Every scenario creates a repository in a temporary directory, gives it role
# files and a release history, and then replays a series of merges through the
# real script, tagging as it goes just like the autotag workflow does. This
# repository is never touched and no network access is needed.

set -euo pipefail

script_under_test="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/compute-next-tag.sh"

failures=0
workdir=''

cleanup() {
	cd /
	if [ -n "$workdir" ]; then
		rm -rf "$workdir"
		workdir=''
	fi
}

trap cleanup EXIT

# Starts a scenario with a repository at Duplicati 2.3.0 which has already seen
# two releases of it (v2.3.0-0 and v2.3.0-1).
#
# The defaults file deliberately carries the traps this role's real one has:
# the Renovate annotation, an image tag derived from the version, and
# `duplicati_container_image_self_build_repo_version`, which is a `_version:`
# line that has nothing to do with the released version. None of them may be
# picked up as the version.
scenario() {
	echo "$1"

	cleanup
	workdir="$(mktemp -d)"

	mkdir -p "$workdir/bin" "$workdir/defaults" "$workdir/meta" "$workdir/tasks" "$workdir/templates"
	cp "$script_under_test" "$workdir/bin/"
	cd "$workdir"

	git init -q -b main .
	git config user.email 'test@example.com'
	git config user.name 'Test'
	git config commit.gpgsign false

	cat > defaults/main.yml <<-'YAML'
		# renovate: datasource=docker depName=linuxserver/duplicati versioning=semver
		duplicati_version: 2.3.0

		duplicati_container_image: "{{ duplicati_container_image_registry_prefix }}linuxserver/duplicati:{{ duplicati_container_image_tag }}"
		duplicati_container_image_tag: "{{ duplicati_version }}"

		duplicati_container_image_self_build_name: "linuxserver/duplicati:{{ duplicati_container_image_self_build_repo_version }}"
		duplicati_container_image_self_build_repo_version: "master"
	YAML
	printf 'placeholder\n' > meta/main.yml
	printf 'placeholder\n' > tasks/main.yml
	printf 'placeholder\n' > templates/env.j2
	printf 'placeholder\n' > README.md

	git add -A
	git commit -qm 'Initial commit'

	local tag
	for tag in v2.3.0-0 v2.3.0-1; do
		git tag "$tag"
	done
}

# Applies a change, commits it, and tags whatever the script says it should be.
# Prints the tag, or nothing when the script decided against a release.
merge() {
	local change="$1" tag

	eval "$change"
	git add -A
	git commit -qm 'Merge'

	tag="$(bin/compute-next-tag.sh 2>/dev/null)"

	if [ -n "$tag" ]; then
		git tag "$tag"
	fi

	printf '%s' "$tag"
}

expect() {
	local description="$1" expected="$2" actual="$3"

	if [ "$actual" = "$expected" ]; then
		printf '  ok   | %s -> %s\n' "$description" "${actual:-no release}"
	else
		printf '  FAIL | %s -> expected %s, got %s\n' "$description" "${expected:-no release}" "${actual:-no release}"
		failures=$((failures + 1))
	fi
}

bump_version="sed -i 's|^duplicati_version: 2.3.0|duplicati_version: 2.4.0|' defaults/main.yml"
revert_version="sed -i 's|^duplicati_version: 2.4.0|duplicati_version: 2.3.0|' defaults/main.yml"
bump_self_build="sed -i 's|^duplicati_container_image_self_build_repo_version: \"master\"|duplicati_container_image_self_build_repo_version: \"nightly\"|' defaults/main.yml"
edit_task="printf 'a task\n' >> tasks/main.yml"
edit_template="printf 'a line\n' >> templates/env.j2"
edit_meta="printf 'metadata\n' >> meta/main.yml"
edit_readme="printf 'documentation\n' >> README.md"
edit_script="printf '# a comment\n' >> bin/compute-next-tag.sh"

# The two merge orders below apply the same updates and must each end up with
# every update released exactly once, whichever order they arrive in.

scenario 'A version bump merged before other role changes'
expect 'version bump' v2.4.0-0 "$(merge "$bump_version")"
expect 'task edit'    v2.4.0-1 "$(merge "$edit_task")"
expect 'template'     v2.4.0-2 "$(merge "$edit_template")"

scenario 'A version bump merged after other role changes'
expect 'task edit'    v2.3.0-2 "$(merge "$edit_task")"
expect 'version bump' v2.4.0-0 "$(merge "$bump_version")"

# `duplicati_container_image_self_build_repo_version` is a `_version:` line
# which tracks a git branch of the container image repository, not a release of
# Duplicati. Reading it as the version would produce a `vmaster-0` tag; reading
# `duplicati_container_image_tag` would produce `v{{-0`.
scenario 'The other version-shaped lines in defaults/main.yml'
expect 'self-build branch bump' v2.3.0-2 "$(merge "$bump_self_build")"
expect 'a task'                 v2.3.0-3 "$(merge "$edit_task")"

scenario 'Commits that do not affect the role'
expect 'README'   ''        "$(merge "$edit_readme")"
expect 'a script' ''        "$(merge "$edit_script")"
expect 'meta'     v2.3.0-2  "$(merge "$edit_meta")"

scenario 'Release numbers past 9'
for release_number in 2 3 4 5 6 7 8 9 10; do
	git tag "v2.3.0-$release_number"
done
expect 'a task' v2.3.0-11 "$(merge "$edit_task")"

scenario 'Reverting to an already released version'
merge "$bump_version" > /dev/null
# The role is now identical to what v2.3.0-1 already published, so there is
# nothing new to release.
expect 'a revert' ''        "$(merge "$revert_version")"

scenario 'Reverting to an already released version, with a change'
merge "$bump_version" > /dev/null
expect 'a revert' v2.3.0-2 "$(merge "$revert_version && $edit_task")"

if [ "$failures" -gt 0 ]; then
	echo >&2 "$failures scenario(s) behaved unexpectedly"
	exit 1
fi

echo 'All scenarios behaved as expected'
