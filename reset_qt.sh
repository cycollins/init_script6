#!/bin/bash

function error_print() {
    >&2 echo "ERROR: $1"
}

function usage() {
    error_print "usage"
    exit 2
}

args=$(getopt :o:b:m:s:d:e:kt $*)
declare -ri arg_error=$?

if (( arg_error != 0 )); then
    usage
fi

set -- $args
for param
do
    case "$param"
    in
        -o)
            org_param="$2"
            shift; shift
            ;;
        -b)
            branch_param="$2"
            shift; shift
            ;;
        -m)
            mirror_repo_name_param="$2"
            shift; shift
            ;;
        -s)
            source_param="$2"
            shift; shift
            ;;
        -d)
            directory_param="$2"
            shift; shift
            ;;
        -e)
            extension_param="$2"
            shift; shift
            ;;
        -k)
            skip_submodules_param=1
            shift
            ;;
        -t)
            trim_empty_param=1
            shift
            ;;
        :)
            shift
            ;;
        ?)
            usage
            ;;
        --)
            shift; break
            ;;
    esac
done

declare -r organization=${org_param:-"blue-ocean-robotics"}
declare -r branch=${branch_param:-"tqtc/lts-5.15.5"}
declare -r mirror_repo_name=${mirror_repo_name_param:-"tqtc-qt5"}
declare -r source_url=${source_param:-"https://codereview.qt-project.org/qt/tqtc-qt5"}
declare -r source_directory_name=${directory_param:-${source_url##*/}}
declare -r branch_name_extension="$extension_param"
declare -ri skip_submodules=${skip_submodules_param:-0}
declare -ri trim_empty=${trim_empty_param:-1}

declare -r mirror_url="https://github.com/${organization}/${mirror_repo_name}.git"

function get_sm_config() {
    local -r sm_to_query="$1"
    local -r config_name="$2"

    local sm_data=$( git config submodule."${sm_to_query}".${config_name} )

    if [[ -z "$sm_data" ]]; then
        sm_data=$( git config --file .gitmodules submodule."${sm_to_query}".${config_name} )
    fi

    echo "$sm_data"
}

function make_repo() {
    local -r new_repo_name="$1"
    local -r new_repo_description="$2"
    local -r new_repo_url=$( hub create -p -d "${new_repo_description}" "${organization}/${new_repo_name}" )
    if [[ -z "$new_repo_url" ]]; then
        error_print "Failed to create repo ${new_repo_name} in organization ${organization}."
        error_print "The most likely reason for this is that the configured user does not"
        error_print "have sufficient or correct permission to create repositories."
        return -1
    fi

    echo "$new_repo_url"
    return 0
}

function get_remote_url() {
    local -r remote_name="$1"
    local -r remotes=$(git remote -v | grep "$remote_name")
    if [[ -n "${remotes}" ]]; then
        local -r extract_pattern="$remote_name"'[[:space:]]+([^[:space:]]+)[[:space:]]+\((fetch|push)\)'
        if [[ ! "$remotes" =~ $extract_pattern ]]; then
            error_print "WARNING - grepping the output from 'git remote -v' for '$remote_name' produced"
            error_print "results, but it is will not parse as expected. This is not recoverable and"
            error_print "script should exit. (get_remote_url probably needs to be rewritten for some Qt change.)"
            return -1
        fi
    else
        # producing an empty string under these conditions is not an error state, It just means there are
        # no remotes defined, which would be fine for example if a repo were entirely local to a machine
        return 0    
    fi

    echo "${BASH_REMATCH[1]}"
    return 0
}

function preflight_repository() {

    local -r mirror_branch="$2"
    local -r repo_url="$1"
    local -r repo_description="$3"
    local -r repo_url_leaf="${repo_url##*/}"
    local -r repo_short_name="${repo_url_leaf%\.git}"

    if git fetch origin; then
        echo "there appears to be a GitHub repository with URL $repo_url. If it has no branch"
        echo "\"$mirror_branch\", we can proceed without impact on this pre-existing URL."
        echo "checking its condition..."

        if git fetch origin "$mirror_branch"; then
            echo "WARNING: it has a branch with the name \"$mirror_branch\". This still may"
            echo "simply be a case of a re-joined configuration that was halted prematurely."
            
            echo "Doing more checks..."

            local -r source_head=$( git rev-parse --verify HEAD )

            if ! git pull --rebase origin "$mirror_branch"; then
                error_print "The existing branch does not cleanly rebase onto the local repository"
                error_print "as we've configured it so far."
                error_print "This is unrecoverable. Exiting."
                return -1
            else
                local -r rebased_head=$( git rev-parse --verify HEAD )

                if [[ "$source_head" != "$rebased_head" ]]; then
                    local -r files_touched=( $( git diff --name-only "$source_head" "$rebased_head" ) )

                    if [[ -z "{$files_touched[*]}" ]]; then
                        echo "no files changed. looks safe to proceed with existing branch and repository"
                    else
                        local -ri file_count=${#files_touched[@]}

                        if [[ file_count -eq 1 ]]  && [[ "${files_touched[0]}" == ".gitmodules" ]]; then
                            echo "The only file touched was .gitmodules, which will be overridden and committed later"
                            echo "so it seems harmless to proceed with partially configured mirror repository and branch."
                        else
                            error_print "There is too much conflict between the local branch and remote branch in"
                            error_print "the existing repository. Exiting. Recommend calling script again using the"
                            error_print "command line - "
                            error_print ".reset_qt $branch $mirror_url $source_url $source_directory_name <foo>"
                            error_print "where \"<foo>\" is an arbitrary extension to the automatically-generated"
                            error_print "branch name. If chosen so that the resulting branch name is unique, then"
                            error_print "the branch will create a new, unique branch in the mirror, initialized based"
                            error_print "on the contents of the official qt repository without local modification."
                            error_print "this can then be compared, merged, or cherry-picked with branches on the"
                            error_print "existing mirror repository as necessary. Deleting the pre-existing remote"
                            error_print "branch that conflicts with the local one is a possibility, but of course"
                            error_print "this introduces the possibility of data loss, so exercise caution!"
                            return -1
                        fi
                    fi
                fi
            fi
        fi
        echo "The repository exists, but there is no conflict between remote and local branches. Safe to proceed."
    else
        echo "There appears to be no existing mirror repository with URL $repo_url."
        echo "Using the hub API to attempt to create one"

        local -r created_repo_url=$( make_repo "$repo_short_name" "$repo_description" )
        if [[ -z "$created_repo_url" ]]; then
            return -1
        fi

        echo "Successfully created repository with short name $repo_short_name at URL $created_repo_url."
        # strip any .git extension from either or both, because it's optional and not significant for comparison
        local -r stripped_repo_url="${created_repo_url%\.git}"
        local -r stripped_mirror_url="${repo_url%\.git}"

        if [[ "$stripped_repo_url" != "$stripped_mirror_url" ]]; then
            error_print "The new repository does not have the same URL ($created_repo_url) as this script run"
            error_print "expected ($repo_url). This will cause problems. Rerun the script from a clean state (i.e. "
            error_print "delete any partially-configured local repository, and rerun the script be sure to call the"
            error_print "script using the new URL for the crated repository. e.g."
            error_print "reset_qt.sh <qt branch e.g. 'tqtc/lts-5.15.5'> <new mirror repo URL> <qt repository URL,"
            error_print "e.g. 'https://codereview.qt-project.org/qt/tqtc-qt5'"
            return -1
        fi
    fi

    return 0
}

function push_to_remote_tracking_branch() {
    local -r tracking_branch="$1"
    local -r remote_url="$2"

    echo "attempting to push the contents of the main module to the mirror repository."
    if ! git push --set-upstream origin "$tracking_branch"; then
        error_print "A remote repository exists but the push failed. If the repository was preexisting, a successful"
        error_print "attempt was made to synchronize remote repository with the state of the local repository and"
        error_print "and to merge (rebase actually) any differences, and still the push failed. Hopefully something in the"
        error_print "command line output has some clues as to what's wrong. Exiting."
        exit -1
    fi

    echo "Successfully pushed the local sources to the mirror repoitory at origin=$remote_url"
    return 0
}

function move_existing_directory() {
    local -r original_folder_name="$1"
    local -r date_time="$( date '+%Y%m%d%H%M%S' )"
    local -i attempt_count=0
    local candidate_folder_name="${original_folder_name}_${date_time}"

    while [[ -d "$candidate_folder_name" ]]; do
        if (( attempt_count == 100 )); then
            error_print "something is wrong with renaming an existing directory. Cannot recover."
            exit -1
        fi

        let "attempt_count++"
        candidate_folder_name="${original_folder_name}-${date_time}-${attempt_count}"
    done

    if ! mv "$original_folder_name" "$candidate_folder_name"; then
        exit -1
    fi
    echo "$candidate_folder_name"
}

function mirror_all_submodules() {
    local -r main_module_full_path=$(pwd)
    local -ra submodule_names=( $(git submodule foreach --quiet 'printf "%s " "$name"') )
    local -ri submodule_count=${#submodule_names[@]}
    local -i current_index=1

    for cmp_name in ${submodule_names[@]}; do
        cd "$main_module_full_path"
        echo -e "mirroring submodule $cmp_name - $current_index out of $submodule_count\n"
        let "current_index++"

        local cmp_url=$( get_sm_config "$cmp_name" url )

        if [[ -z "$cmp_url" ]]; then
            # it's iffy to try to come up with a default because the documentation is vague
            # for the case where an "url" setting is missing, but the following seems reasonable
            # and it is only being used to symthesize a new name URL for the mirror. The truth is,
            # if this warning comes up, the user should take a hard look at the source repository
            # layout and see if it being successfully inited.

            echo "WARNING: using ../${cmp_name} as URL for the submodule \"${cmp_name}\" because"
            echo "none is specied explicitly."
            cmp_url="../${cmp_name}"
        fi

        local repo_leaf="${cmp_url##*/}"
        local cmp_path=$( get_sm_config "$cmp_name" path )

        if [[ -z "$cmp_path" ]]; then
            # same comment for cmp_path as for cmp_url above. You should probably never be here
            # so if the warning occurrs, there's cause to examine closely the what the developers
            # intended.

            echo "WARNING: using $cmp_name as path for the submodule \"${cmp_name}\" because"
            echo "none is specied explicitly."
            cmp_path="$cmp_name"
       fi

        cd "$cmp_path"
        mirror_all_submodules
        
        local submodule_mirror_url="${base_url_str}/${repo_leaf}"

        if ! git checkout -b "$mirror_branch_name"; then
            error_print "Problem creating branch in submodule. Cannot recover. Exiting."
        fi

        echo "updating named remotes origin to reflect the mirror github site"

        local remote_sub_url=$( get_remote_url "origin" )

        if [[ "$remote_sub_url" != "$submodule_mirror_url" ]]; then
            if [[ -n "$remote_sub_url" ]]; then
                if git remote remove origin; then
                    echo "a non-trivial origin with URL not equal to $submodule_mirror_url"
                    echo "was removed to occommodate the mirror repository URL"
                else
                    error_print "failed an attempt to remove an origin with URL not equal to"
                    error_print "$submodule_mirror_url. This is unrecoverable. Git feedback"
                    error_print "may help in diagnosing the problem. Exiting"
                    exit -1
                fi
            fi
            echo "setting origin remote URL to $submodule_mirror_url..."
        
            if ! git remote add origin "$submodule_mirror_url"; then
                error_print "attempt to establish origin remote URL failed. Exiting"
                exit -1
            fi
        else
            echo "No Update required"
        fi

        echo "checking for an existing mirror repository for the main module and evaluating state"

        if ! preflight_repository "$submodule_mirror_url" "$mirror_branch_name" "mirror of qt component \"$cmp_name\""; then
            exit -1
        fi
    
        echo "remote origin URL is $submodule_mirror_url"
        echo "Attempting to push the state of the local directory to mirror remote $submodule_mirror_url"

        if ! push_to_remote_tracking_branch "$main_module_branch" "$submodule_mirror_url"; then
            exit -1
        fi
        echo -e "---------------------------------------------------------------------------------------\n\n"
    done

    cd $main_module_full_path
}

# if there's a local folder with the right name, rename it - we only work from a clean checkout as
# a simplifying assumption

echo "Cloning into $source_directory_name..."
if [[ -d "$source_directory_name" ]]; then
    echo "A folder named ${source_directory_name} exists already."
    declare -r new_directory_name=$( move_existing_directory "$source_directory_name" )
    echo "Renamed exixting directory to $new_directory_name"
fi

if [[ ! -d "$source_directory_name" ]]; then
    if ! git clone "$source_url" "$source_directory_name"; then
        error_print "Error cloning from repository at $source_url. Cannot proceed. Exiting."
    fi

    if [[ ! -d "$source_directory_name" ]]; then
        error_print "we cloned from $source_url, expecting the resulting directory to"
        error_print "be called $source_directory_name, but no such directory exists."
        error_print "Can't recover from this. Reassess parameters to this script, and rerun."
        exit -1
    fi

    echo "Setting cwd to $source_directory_name"
    cd "$source_directory_name"

    if ! git checkout "$branch"; then
        error_print "failed to checkout \"$branch\", which was the specified basis for"
        error_print "for our mirror branch. Check for available branches and rerun the"
        error_print "script. Exiting."
        exit -1
    fi

    declare -a init_command=( 'perl init-repository' '' "--branch --module-subset essential,qtimageformats,qtlocation,qtsensors,qtsvg,qtvirtualkeyboard,qtwebview,qtwebengine,qtwebchannel,qtxmlpatterns,qtserialport,qtwebsockets,qtactiveqt" )
    if ! ${init_command[*]}; then
        init_command[1]='-f'

        echo "needed a forced update"

        if ! ${init_command[*]}; then
            error_print "perl reports a problem with executing the init-repository script."
            error_print "This is suspicious, so exiting as an error."
            exit -1
        fi
    fi
fi

current_branch="$(git branch --show-current)"

declare -r branch_pattern='([0-9]+(\.[0-9]+)+)'

if [[ "$branch" =~ $branch_pattern ]]; then
    declare -r mirror_branch_name="st-${BASH_REMATCH[1]}${branch_name_extension}"
else
    error_print "We expect to be able to derive version information from Qt's branch name in"
    error_print "<major>.<minor>.<revision> format, but can't parse current branch name"
    error_print "\"$current_branch_name\" for this information. If this is due to some change"
    error_print "in Qt's practices, this script needs to be revisited."
    exit -1
fi

# if the current branch has the name synthesized above, we'll assume that we are rejoining
# a partially-completed setup, and that the local branch has already been addressed

if [[ "$current_branch" != "$mirror_branch_name" ]]; then
    echo "Changing local branch to \"$mirror_branch_name\""
    declare -r branch_head=$( git rev-parse --verify HEAD )
    echo "on branch \"$branch\". Creating \"$mirror_branch_name\" off of it for our mirror."
    if git checkout "$mirror_branch_name"; then
        echo "WARNING: \"$mirror_branch_name\" already exists This should not happen, unless"
        echo "this script specified that our mirror branch should use the same branch name as the source"
        echo "repository. This is suspicious, but not cause for exiting."

        declare -r mirror_branch_head=$( git rev-parse --verify HEAD )

        if [[ "$branch_head" == "$mirror_branch_head" ]]; then
            echo "Branch heads match. Fairly safe to proceed."
        else
            error_print "Qt repository branch head $branch_head does not match mirror branch head $mirror_branch_head."
            error_print "This is not a good sign. Exiting."
            exit -1
        fi
    elif git checkout -b "$mirror_branch_name"; then
        echo "created and checked out\"$mirror_branch_name\""
    else
        error_print "cannot checkout \"$mirror_branch_name\". Observe git feedback"
        error_print "for clues. Exiting."
        exit -1
    fi
fi

declare -r main_module_branch=$( git branch --show-current )
if [[ $? -ne 0 ]] || [[ -z "main_module_branch" ]] || [[ "$main_module_branch" != "$mirror_branch_name" ]]; then
    error_print "The current branch \"$main_module_branch\" is not what it should be - \"$mirror_branch_name\"."
    error_print "This is non-recoverable state. Check git output for clues as to the problem."
    exit -1
fi

echo "getting current remote \"upstream\""
declare -r upstream_url=$( get_remote_url "upstream" )
[[ $? -ne 0 ]] && exit -1

if [[ -z "$upstream_url" ]]; then
    echo "getting current remote \"origin\""
    origin_url=$(get_remote_url "origin")
    [[ $? -ne 0 ]] && exit -1

    if [[ -n "$origin_url" ]] && [[ "$origin_url" == "$source_url" ]]; then
        echo "There is no \"upstream\" remote, but there is a fetch remote named"
        echo "\"origin\" with URL $origin_url, which is the expected state after"
        echo "a clean clone and checkout, or if a previous setup was interruped prior to"
        echo "this point. We will proceed on that assumption."

        echo "creating \"upstream\" remote with URL $origin_url"
        if ! git remote add upstream "$origin_url"; then
            error_print "cannot establish $origin_url as the new \"upstream\" remote. Can't recover."
            exit -1
        fi

        echo "removing current \"origin\" remote with URL $origin_url"
        if ! git remote remove origin; then
            error_print "cannot remove remote \"origin\". Can't recover."
            exit -1
        fi

        echo "adding new remote \"origin\" with URL $mirror_url"
        if ! git remote add origin $mirror_url; then
            error_print "cannot create new \"origin\" remote. Can't recover."
            exit -1
        fi
    elif [[ "$origin_url" == "$mirror_url" ]] && [[ "$upstream_url" == "$source_url" ]]; then
        error_print "The \"upstream\" remote has URL "$source_url" and the \"origin\" remote"
        error_print "has URL $mirror_url coming into the remote configuration part of this script."
        error_print "We appear to be attempting to clone both from and to a remote with the"
        error_print "same URL. Too weird for this script. Exiting."
        exit -1
    else
        error_print "some unrecoverable state or error has been encounered while trying to setup"
        error_print "remotes for the mirror repository. The git output should provide some useful"
        error_print "clues as to why. Try to address the problem, delete the local repository, and"
        error_print "run the script again."
        exit -1
    fi
fi

echo "checking for an existing mirror repository for the main module and evaluating state"

if ! preflight_repository "$mirror_url" "$mirror_branch_name" "mirror of top-level QT repository"; then
    exit -1
fi

if ! push_to_remote_tracking_branch "$main_module_branch" "$mirror_url"; then
    exit -1
fi

if (( skip_submodules == 0 )); then
    echo -e "\n\n mirroring submodules\n"

    declare -r base_url_str="${mirror_url%/*}"

    mirror_all_submodules
fi

echo "Successfully mirrored qt repository from $source_url to $mirror_url"
