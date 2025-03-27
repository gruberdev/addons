#!/usr/bin/with-contenv bashio
# vim: ft=bash
# shellcheck shell=bash

# shellcheck disable=SC2034
CONFIG_PATH=/data/options.json
HOME=~

DEPLOYMENT_KEY=$(bashio::config 'deployment_key')
DEPLOYMENT_KEY_PROTOCOL=$(bashio::config 'deployment_key_protocol')
DEPLOYMENT_USER=$(bashio::config 'deployment_user')
DEPLOYMENT_PASSWORD=$(bashio::config 'deployment_password')
GIT_BRANCH=$(bashio::config 'git_branch')
GIT_COMMAND=$(bashio::config 'git_command')
GIT_REMOTE=$(bashio::config 'git_remote')
GIT_PRUNE=$(bashio::config 'git_prune')
REPOSITORY=$(bashio::config 'repository')
AUTO_RESTART=$(bashio::config 'auto_restart')
RESTART_IGNORED_FILES=$(bashio::config 'restart_ignore | join(" ")')
REPEAT_ACTIVE=$(bashio::config 'repeat.active')
REPEAT_INTERVAL=$(bashio::config 'repeat.interval')
################

#### functions ####
function add-ssh-key {
    bashio::log.info "[Info] Start adding SSH key"
    mkdir -p ~/.ssh

    (
        echo "Host *"
        echo "    StrictHostKeyChecking no"
    ) > ~/.ssh/config

    bashio::log.info "[Info] Setup deployment_key on id_${DEPLOYMENT_KEY_PROTOCOL}"
    rm -f "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    while read -r line; do
        echo "$line" >> "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    done <<< "$DEPLOYMENT_KEY"

    chmod 600 "${HOME}/.ssh/config"
    chmod 600 "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
}

function git-clone {
    # create backup
    BACKUP_LOCATION="/tmp/config-$(date +%Y-%m-%d_%H-%M-%S)"
    bashio::log.info "[Info] Backup configuration to $BACKUP_LOCATION"

    mkdir "${BACKUP_LOCATION}" || bashio::exit.nok "[Error] Creation of backup directory failed"
    # Use rsync for potentially better handling of existing files/permissions if needed, but cp is fine
    cp -arf /config/* "${BACKUP_LOCATION}/" || bashio::exit.nok "[Error] Copy files to backup directory failed"

    # remove config folder content
    bashio::log.info "[Info] Clearing /config directory..."
    # Ensure we are in the parent directory to avoid deleting the target dir itself
    (cd / && rm -rf config/* config/.[!.]* config/..?*) || bashio::exit.nok "[Error] Clearing /config failed"

    # git clone
    bashio::log.info "[Info] Start git clone of main repository from $REPOSITORY"
    git clone --branch "$GIT_BRANCH" "$REPOSITORY" /config || bashio::exit.nok "[Error] Git clone failed"

    # Navigate into the repository
    cd /config || bashio::exit.nok "[Error] Failed to cd into /config after clone";

    # Initialize submodules using Taskfile
    bashio::log.info "[Info] Running Taskfile update task for initial submodule setup..."
    if ! task update; then
        # Attempt to restore backup if task fails on initial clone
        bashio::log.error "[Error] Taskfile update task failed during initial clone. Attempting restore from backup..."
        rm -rf /config/{,.[!.],..?}* # Clear failed clone/task attempt
        cp -arf "${BACKUP_LOCATION}/"* /config/ || bashio::log.warning "[Warn] Failed to restore backup from ${BACKUP_LOCATION}"
        bashio::exit.nok "[Error] Taskfile update failed. Restore attempted."
    fi

    # try to copy non yml files back (excluding taskfile itself)
    bashio::log.info "[Info] Restoring non-YAML files from backup (excluding Taskfile.*)..."
    find "${BACKUP_LOCATION}" -maxdepth 1 -type f ! -name '*.yaml' ! -name '*.yml' ! -name 'Taskfile.*' -exec cp -pf {} /config/ \; 2>/dev/null

    # try to copy secrets file back
    bashio::log.info "[Info] Restoring secrets.yaml from backup..."
    if [ -f "${BACKUP_LOCATION}/secrets.yaml" ]; then
        cp -pf "${BACKUP_LOCATION}/secrets.yaml" /config/ 2>/dev/null
    fi

    bashio::log.info "[Info] Initial clone and submodule setup complete."
}

function check-ssh-key {
    if [ -n "$DEPLOYMENT_KEY" ]; then
        bashio::log.info "Check SSH connection"
        # Improved parsing for ssh URLs like git@github.com:user/repo.git
        local domain_part
        if [[ "$REPOSITORY" == *@* ]]; then
            domain_part="${REPOSITORY#*@}" # Remove user part if present
            domain_part="${domain_part%%:*}" # Get the domain before the colon
        else
            # Handle https/http URLs (though less relevant for SSH key check)
             domain_part=$(echo "$REPOSITORY" | sed -E 's#^.*://([^@/]*@)?([^/:]+).*#\2#')
        fi

        if [ -z "$domain_part" ]; then
             bashio::log.warning "[Warn] Could not determine domain from repository URL: $REPOSITORY"
             add-ssh-key # Add key anyway if domain parsing failed
             return
        fi

        # Use the extracted domain for the check
        local check_user_host
        if [[ "$REPOSITORY" == *@* ]]; then
             check_user_host="${REPOSITORY%%:*}" # Use the full user@host part
        else
             check_user_host="git@${domain_part}" # Assume git user for check if not specified
             bashio::log.info "[Info] Assuming user 'git' for SSH check to $domain_part"
        fi

        bashio::log.info "[Info] Testing SSH connection to $check_user_host..."
        # shellcheck disable=SC2029
        if OUTPUT_CHECK=$(ssh -T -o "StrictHostKeyChecking=no" -o "BatchMode=yes" "$check_user_host" 2>&1) || \
           { [[ "$OUTPUT_CHECK" == *"successfully authenticated"* ]] && [[ "$OUTPUT_CHECK" != *"Permission denied"* ]]; }; then
            bashio::log.info "[Info] SSH connection successful for $check_user_host"
            bashio::log.debug "[Debug] SSH Output: $OUTPUT_CHECK"
        else
            bashio::log.warning "[Warn] SSH connection test failed for $check_user_host."
            bashio::log.debug "[Debug] SSH Output: $OUTPUT_CHECK"
            add-ssh-key
        fi
    fi
}

function setup-user-password {
    # Only setup if user is provided and it's an HTTPS repository
    if [ -n "$DEPLOYMENT_USER" ] && [[ "$REPOSITORY" == https://* ]]; then
        # Ensure we are in the repository directory
        # This function might be called before clone, so check existence
        if [ -d "/config/.git" ]; then
           cd /config || return
        else
           bashio::log.warning "[Warn] Cannot setup user/password - /config is not a git repository yet."
           return
        fi

        bashio::log.info "[Info] Setting up credential.helper for user: ${DEPLOYMENT_USER}"
        # Use store helper - consider security implications of storing password in plain text
        # Alternatives: cache helper (temporary), or OS-specific credential managers if available
        git config credential.helper 'store --file=/tmp/git-credentials'

        # Extract the hostname from repository URL for credential storage
        local h="$REPOSITORY"
        local proto=${h%%://*}
        h="${h#*://}" # Strip protocol
        # Strip potential user:pass@ prefix if user accidentally included it
        h="${h#*@}"
        # Get only the host part
        local host=${h%%/*}

        # Format the input for git credential commands
        local cred_data="protocol=${proto}\nhost=${host}\nusername=${DEPLOYMENT_USER}\npassword=${DEPLOYMENT_PASSWORD}\n"

        # Use git credential approve to store the credentials
        bashio::log.info "[Info] Saving git credentials to /tmp/git-credentials for host ${host}"
        # The redirection <<< sends the string as standard input
        if ! git credential approve <<< "$cred_data"; then
             bashio::log.warning "[Warn] Failed to store git credentials."
        fi
        # Ensure the credential file is only readable by the user (though still plain text)
        chmod 600 /tmp/git-credentials
    elif [ -n "$DEPLOYMENT_USER" ] && [[ "$REPOSITORY" != https://* ]]; then
        bashio::log.info "[Info] Deployment user/password provided, but repository is not HTTPS. Skipping credential setup."
    fi
}

function git-synchronize {
    # is /config a local git repo?
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        bashio::log.warning "[Warn] /config is not a Git repository. Attempting initial clone."
        # Setup credentials *before* clone if needed for HTTPS
        setup-user-password
        git-clone
        # git-clone function now handles cd and initial task run
        return 0 # Indicate success if clone and task worked
    fi

    bashio::log.info "[Info] Local git repository exists in /config"
    # Ensure we are in the repository directory
    cd /config || bashio::exit.nok "[Error] Failed to cd into /config";

    # Is the local repo set to the correct origin?
    local CURRENTGITREMOTEURL
    CURRENTGITREMOTEURL=$(git remote get-url --all "$GIT_REMOTE" | head -n 1)
    if [ "$CURRENTGITREMOTEURL" != "$REPOSITORY" ]; then
        bashio::log.error "[Error] Git remote '$GIT_REMOTE' URL does not match configured repository!"
        bashio::log.error "[Error] Expected: $REPOSITORY"
        bashio::log.error "[Error] Found:    $CURRENTGITREMOTEURL"
        bashio::exit.nok "[Error] Mismatched repository URL."
        return 1 # Indicate failure
    fi

    bashio::log.info "[Info] Git remote '$GIT_REMOTE' is correctly set to $REPOSITORY"
    local OLD_COMMIT
    OLD_COMMIT=$(git rev-parse HEAD)

    # Setup credentials before fetch/pull if needed
    setup-user-password

    # Always do a fetch to update remote refs
    bashio::log.info "[Info] Start git fetch ($GIT_REMOTE $GIT_BRANCH)..."
    # Fetch only the specific branch to be efficient
    git fetch "$GIT_REMOTE" "$GIT_BRANCH" || bashio::exit.nok "[Error] Git fetch failed";

    # Prune if configured
    if bashio::config.true 'git_prune'; then
        bashio::log.info "[Info] Start git prune..."
        git prune "$GIT_REMOTE" || bashio::log.warning "[Warn] Git prune failed"; # Don't exit on prune failure
    fi

    # Do we switch branches?
    local GIT_CURRENT_BRANCH
    GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
    if [ -z "$GIT_BRANCH" ] || [ "$GIT_BRANCH" == "$GIT_CURRENT_BRANCH" ]; then
        bashio::log.info "[Info] Staying on currently checked out branch: $GIT_CURRENT_BRANCH..."
        # Ensure the branch tracks the remote branch correctly
        git branch --set-upstream-to="$GIT_REMOTE/$GIT_BRANCH" "$GIT_CURRENT_BRANCH" || bashio::log.warning "[Warn] Failed to set upstream branch."
    else
        bashio::log.info "[Info] Switching branches - start git checkout of branch $GIT_BRANCH..."
        # Checkout the branch, setting upstream tracking
        git checkout --track "$GIT_REMOTE/$GIT_BRANCH" || git checkout "$GIT_BRANCH" || bashio::exit.nok "[Error] Git checkout failed"
        GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
        if [ "$GIT_BRANCH" != "$GIT_CURRENT_BRANCH" ]; then
             bashio::exit.nok "[Error] Failed to switch to branch $GIT_BRANCH. Current branch is $GIT_CURRENT_BRANCH."
        fi
    fi

    # Pull or reset depending on user preference
    case "$GIT_COMMAND" in
        pull)
            bashio::log.info "[Info] Start git pull..."
            # Use --ff-only to avoid merge commits if desired, or handle conflicts manually
            # Default pull allows merges. Add options if needed e.g., --rebase
            git pull "$GIT_REMOTE" "$GIT_BRANCH" || bashio::exit.nok "[Error] Git pull failed";
            ;;
        reset)
            bashio::log.info "[Info] Start git reset --hard to $GIT_REMOTE/$GIT_CURRENT_BRANCH..."
            # Ensure we have the latest ref from fetch before resetting
            git reset --hard "$GIT_REMOTE/$GIT_CURRENT_BRANCH" || bashio::exit.nok "[Error] Git reset failed";
            ;;
        *)
            bashio::exit.nok "[Error] Git command ('$GIT_COMMAND') is not set correctly. Should be either 'reset' or 'pull'"
            ;;
    esac

    # Update submodules using Taskfile AFTER pull/reset
    bashio::log.info "[Info] Running Taskfile update task to synchronize submodules..."
    task update || bashio::exit.nok "[Error] Taskfile update task failed after sync."

    # Store the new commit hash *after* potential submodule updates (which might commit changes)
    # Re-read OLD_COMMIT here to pass to validate-config
    export OLD_COMMIT # Export so validate-config can see it
    return 0 # Indicate success
}

function validate-config {
    # This function expects OLD_COMMIT to be set by git-synchronize
    local current_commit
    current_commit=$(git rev-parse HEAD)

    bashio::log.info "[Info] Checking if repository state has changed..."
    # Also check if submodules caused changes (git status)
    if [ "$current_commit" == "$OLD_COMMIT" ] && git diff --quiet HEAD && git diff --quiet --cached HEAD; then
        bashio::log.info "[Info] No changes detected in repository state or working directory."
        return
    fi

    bashio::log.info "[Info] Repository state changed (Old: $OLD_COMMIT, New: $current_commit) or working dir modified. Checking Home-Assistant config..."
    if ! bashio::core.check; then
        bashio::log.error "[Error] Configuration updated but it does not pass the config check. Do not restart until this is fixed!"
        return
    fi

    if ! bashio::config.true 'auto_restart'; then
        bashio::log.info "[Info] Local configuration has changed and passes check. Auto-restart disabled, manual restart may be required."
        return
    fi

    local DO_RESTART="false"
    # Check diff including staged changes and submodule updates if they were committed by 'task update'
    # Use three dots to compare working tree against OLD_COMMIT
    local CHANGED_FILES
    CHANGED_FILES=$(git diff "$OLD_COMMIT"...HEAD --name-only)

    if [ -z "$CHANGED_FILES" ]; then
         # If diff is empty, check working dir/index status in case task update didn't commit
         if git diff --quiet HEAD && git diff --quiet --cached HEAD; then
             bashio::log.info "[Info] Commits changed but diff is empty and working dir clean? No files requiring restart identified."
             return
         else
             bashio::log.warning "[Warn] Working directory or index modified after sync/task. Assuming restart potentially needed."
             # Get list of modified/untracked files (less precise than diff)
             CHANGED_FILES=$(git status --porcelain | awk '{print $2}')
         fi
    fi

    bashio::log.info "Changed/Modified Files potentially requiring restart:"
    echo "$CHANGED_FILES" # Print list for clarity

    if [ -n "$RESTART_IGNORED_FILES" ]; then
        bashio::log.info "[Info] Checking changed files against ignored patterns: $RESTART_IGNORED_FILES"
        local requires_restart="false"
        # Read files line by line to handle spaces in names correctly
        echo "$CHANGED_FILES" | while IFS= read -r changed_file; do
            local is_ignored="false"
            for restart_ignored_pattern in $RESTART_IGNORED_FILES; do
                # Use bash pattern matching (more robust than grep for paths)
                # [[ $changed_file == $restart_ignored_pattern ]] # Exact match
                # [[ $changed_file == $restart_ignored_pattern/* ]] # Starts with dir
                # Use extended glob for more flexibility if needed: shopt -s extglob
                # Check if the changed file path starts with the ignored pattern (treats pattern as prefix)
                # Or if it's an exact match
                if [[ "$changed_file" == "$restart_ignored_pattern" || "$changed_file" == "$restart_ignored_pattern/"* ]]; then
                    bashio::log.info "[Info] Ignored file/path change detected: $changed_file (matches: $restart_ignored_pattern)"
                    is_ignored="true"
                    break # Stop checking patterns for this file
                fi
            done
            if [ "$is_ignored" == "false" ]; then
                bashio::log.info "[Info] Detected restart-required file change: $changed_file"
                requires_restart="true"
                # We can break the outer loop early if we only need one reason to restart
                # break
            fi
        done

        if [ "$requires_restart" == "true" ]; then
            DO_RESTART="true"
        fi
    else
        # If no ignore list, any change triggers restart
        bashio::log.info "[Info] No ignored files configured. Any change triggers restart."
        DO_RESTART="true"
    fi

    if [ "$DO_RESTART" == "true" ]; then
        bashio::log.notice "[Notice] Restarting Home-Assistant due to configuration changes..."
        bashio::core.restart
    else
        bashio::log.info "[Info] No restart required, only ignored changes detected or no changes found."
    fi
}

###################

#### Main program ####

# Check if Task command exists
if ! command -v task &> /dev/null; then
    bashio::exit.nok "[Fatal] 'task' command not found. Please install Go Task (taskfile.dev) in this environment."
fi
bashio::log.info "[Info] Found 'task' command."

# Initial setup: Move into target directory if it exists, otherwise functions will handle it
if [ -d "/config" ]; then
  cd /config || bashio::exit.nok "[Error] Failed to cd into /config at start";
else
  mkdir -p /config || bashio::exit.nok "[Error] Failed to create /config directory at start";
  cd /config || bashio::exit.nok "[Error] Failed to cd into /config after creation";
fi


while true; do
    bashio::log.info "[Info] Starting synchronization cycle..."
    # Check SSH key validity *before* git operations needing SSH
    check-ssh-key

    # git-synchronize handles clone/pull/reset and runs 'task update'
    # It also handles cd /config
    if git-synchronize ; then
        # validate-config checks for changes *after* sync and task run, then restarts if needed
        # It needs OLD_COMMIT from git-synchronize
        validate-config
    else
      bashio::log.error "[Error] git-synchronize function failed. Skipping validation."
      # Decide if you want to exit or retry after failure
      # exit 1 # Exit if sync fails critically
    fi

    # do we repeat?
    if ! bashio::config.true 'repeat.active'; then
        bashio::log.info "[Info] Repeat disabled. Exiting synchronization loop."
        exit 0
    fi

    bashio::log.info "[Info] Repeat active. Sleeping for $REPEAT_INTERVAL seconds..."
    sleep "$REPEAT_INTERVAL"
done

###################
