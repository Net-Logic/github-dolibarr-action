#!/bin/bash

set -o pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
module=${MODULE}
classname=${CLASSNAME}
release_branches=${RELEASE_BRANCHES:-master,main}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-v0.0.0}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-true}
# old_version=$(grep ">version" core/modules/mod${classname}.class.php | awk '{print $3}')
old_version=$(sed -rn "/.*->version\s*=\s*('|\")(.*)'.*$/p" core/modules/mod${classname}.class.php | cut -d "'" -f 2)
echo "old_version = $old_version"
echo "module_version=$old_version" >> $GITHUB_ENV

cd ${GITHUB_WORKSPACE}/${source}
echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tMODULE: ${module}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"

current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="true"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    echo "Is $b a match for ${current_branch}"
    if [[ "${current_branch}" =~ $b ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = $pre_release"
echo "tag_context = $tag_context"

# fetch tags
git fetch --tags

tagFmt="^v?[0-9]+\.[0-9]+\.[0-9]+$"
echo "tagFmt = $tagFmt"
preTagFmt="^v?[0-9]+\.[0-9]+\.[0-9]+(-$suffix\.[0-9]+)?$"
echo "preTagFmt = $preTagFmt"

# get latest tag that looks like a semver (with or without module name)
case "$tag_context" in
    *repo*)
        #taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$tagFmt")"
        tag=v"$(semver "$old_version" | tail -n 1)"

        #pre_taglist="$(git for-each-ref --sort=-v:refname --format '%(refname:lstrip=2)' | grep -E "$preTagFmt")"
        pre_tag="$(semver "$old_version}" | tail -n 1)"
        ;;
    *branch*)
        taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$tagFmt")"
        tag=v"$(semver "${taglist}" | tail -n 1)"

        pre_taglist="$(git tag --list --merged HEAD --sort=-v:refname | grep -E "$preTagFmt")"
        pre_tag=$(semver "${pre_taglist}" | tail -n 1)
        ;;
    * ) echo "Unrecognised context"; exit 1;;
esac

echo "new tag = $tag"

# if there are none, start tags at INITIAL_VERSION which defaults to 0.0.0
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    tag="$initial_version"
    if [ -z "$pre_tag" ] && $pre_release
    then
      pre_tag="$initial_version"
    fi
else
    log=$(git log $tag...HEAD --pretty='%B')
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 $tag)

# get current commit hash
commit=$(git rev-parse HEAD)

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping..."
    echo ::set-output name=tag::$tag
    exit 0
fi

# echo log if verbose is wanted
if $verbose
then
  echo $log
fi

case "$log" in
    *#major* ) new=$(semver -i major $tag); part="major";;
    *#minor* ) new=$(semver -i minor $tag); part="minor";;
    *#patch* ) new=$(semver -i patch $tag); part="patch";;
    *#none* )
        echo "Default bump was set to none. Skipping..."; echo ::set-output name=new_tag::$tag; echo ::set-output name=tag::$tag; exit 0;;
    * )
        if [ "$default_semvar_bump" == "none" ]; then
            echo "Default bump was set to none. Skipping..."; echo ::set-output name=new_tag::$tag; echo ::set-output name=tag::$tag; exit 0
        else
            new=$(semver -i "${default_semvar_bump}" $tag); part=$default_semvar_bump
        fi
        ;;
esac

if $pre_release
then
    # Already a prerelease available, bump it
    if [[ "$pre_tag" == *"$new"* ]]; then
        new=$(semver -i prerelease $pre_tag --preid $suffix); part="pre-$part"
    else
        new="$new-$suffix.1"; part="pre-$part"
    fi
fi

echo $part
echo $new

sed -i "s/$old_version/$new/" core/modules/mod${classname}.class.php

# prefix with modulename-
new="v$new"

if $pre_release
then
    echo -e "Bumping tag ${pre_tag}\n\tNew tag ${new}"
    echo "{module_version}=${pre_tag}"
    echo "{module_version}=${pre_tag}" >> $GITHUB_ENV
else
    echo -e "Bumping tag ${tag}\n\tNew tag ${new}"
    echo "{module_version}=${tag}"
    echo "{module_version}=${tag}" >> $GITHUB_ENV
fi

# set outputs
echo ::set-output name=new_tag::$new
echo ::set-output name=part::$part

# use dry run to determine the next tag
if $dryrun
then
    echo ::set-output name=tag::$tag
    exit 0
fi

echo ::set-output name=tag::$new

# create local git tag
git tag $new

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/sha}//g')

echo "$dt: **pushing tag $new to repo $full_name"

git_refs_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF
{
  "ref": "refs/tags/$new",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
