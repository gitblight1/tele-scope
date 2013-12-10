# tele-scope.sh
#
# moves the current (local) changeset up one level:
# 1) stashes changeset and moves to master to apply it
# 2) commits changeset and pushes to the remote origin
# 3) returns to local branch and rebases onto master
#
# Usage: tele-scope [OPTIONS]
# 
# options:
# -b, --norebase: Return to the local branch, but do not rebase.
# -c, --noclear:  Do not remove the stashed changes. By default,
#                 the stash will be removed after rebasing.
# -e, --email:    Use next argument as user.email.
# -m, --message:  Use next (quoted) argument as commit message.
# -n, --branch:   Use next argument as <upstream> for rebasing.
#                 Default is master
# -p, --pull:     Pull from the remote repo before committing.
# -r, --remote:   Use the next argument as the remote repository.
#                 If this argument is "--", do not push changes.
# -u, --user:     Use next argument as user.name (put in quotes).
#                 user.name and user.email config settings are
#                 used if the arguments are not supplied.
#
# This script comes with the following caveats and warnings:
# - If your current branch is part of a public repository, think very
#   carefully about whether you want to rebase. If just the master
#   is part of a public repository, it's far less likely that you'll
#   cause trouble, but make sure you're up-to-date if
#   you're worried that other people have been pushing to that branch.
# - This script does NOT merge after rebasing. It is assumed that if you 
#   wanted to do that, you wouldn't bother stashing changes; you'd just
#   commit, rebase, and merge. The idea of this script is that you have
#   some (previously committed) changes on the current branch that you
#   don't want on master.
# - If there is a problem at any step, the script will attempt to back out
#   any changes. The stash will not be deleted until the changes are
#   committed and pushed, and the current branch has been rebased.

tele-scope() {
    # exit statuses
	local -i SUCCESS=0
	local -i BRANCHERROR=1
	local -i STASHERROR=2
	local -i COMMITERROR=3
	local -i REMOTEERROR=4
	local -i CONFLICTS=5
	local -i HELP=126
	local -i ARGERROR=127

	# option variables
	local -i REBASE=0
	local -i CLEAR=0
	local -i PULL=0
	local username=''
	local usermail=''
	local authorstring=''
	local message=''
	local msgflag=''
	local authflag='--author'
	local upstream='master'
	local remote='origin'

	# TEMP can't be local because it screws up the exit status
	TEMP=$(getopt -n tele-scope -o bce:hm:n:pr:u: \
		--long norebase,noclear,email:,help,message:,branch:,pull,remote:,user: \
		-- "$@")
	# If bad args, print usage statment and exit
	if [ $? -ne 0 ];then
		echo "Use tele-scope -h for usage statment"
		unset TEMP
		return $ARGERROR
	fi

	eval set -- "$TEMP"
	while true; do
		case $1 in
			-b|--norebase)
				REBASE=1; shift; continue
				;;
			-c|--noclear)
				CLEAR=1; shift; continue
				;;
			-e|--email)
				usermail="$2"; shift; shift; continue
				;;
			-h|--help)
				echo "Usage: tele-scope [OPTIONS] [FILES]
Move [FILES] from the current (local) changeset to an upstream branch:
1) stashes changeset and moves upstream to apply it
2) commits changeset and pushes to the remote origin
3) returns to local branch and rebases onto the upstream branch
If no files are specified, all changes are moved. If files are
specified, the stash will be re-applied after rebasing.

options:
 -b, --norebase: Return to the local branch, but do not rebase.
 -c, --noclear:  Do not remove the stashed changes. If By default,
                 the stash will be dropped after rebasing.
 -e, --email:    Use next argument as user.email.
 -h, --help:     Print this message.
 -m, --message:  Use next (quoted) argument as commit message.
                 If blank, git commit will open an editor.
 -n, --branch:   Use next argument as <upstream> for rebasing.
                 Default is master.
 -p, --pull:     Pull from the remote repo before committing.
 -r, --remote:   Use the next argument as the remote repository.
                 If this argument is "--", do not push changes.
                 Default is origin.
 -u, --user:     Use next argument as user.name (put in quotes).
                 user.name and user.email default to the settings
                 in the <upstream> branch; if these do not exist, 
                 current branch options are used."
				return $SUCCESS
				;;
			-m|--message)
				msgflag=''
				message="$2"; shift; shift; continue
				;;
			-n|--branch)
				upstream="$2"; shift; shift; continue
				;;
			-p|--pull)
				PULL=1; shift; continue
				;;
			-r|--remote)
				remote="$2"; shift; shift; continue
				;;
			-u|--user)
				username="$2"; shift; shift; continue
				;;
			--) # no more arguments
				break
				;;
			*)
				printf "Unknown option %s\n" "$1"
				return $ARGERROR
				;;
		esac
	done
	eval set -- "$@"
	unset TEMP # do this right away

	# If we're not in a working tree, bail out now
	if [ "true" != "$(git rev-parse --is-inside-work-tree 2>/dev/null)" ]
	then
		echo "tele-scope: must be run inside a valid working tree."
		return $BRANCHERROR
	fi

	# get important info from local branch
	local thisbranch="$(git branch 2>/dev/null | grep '*' | sed 's/* \(.*\)/\1/')"
	if [ -z "$thisbranch" ]; then
		echo "Cannot determine branch. Exiting."
		return $BRANCHERROR
	fi

 	local localuser="$(git config user.name)"
	local localmail="$(git config user.email)"

	# check for (unstaged or staged) changes
	local changes='no'
	git diff --no-ext-diff --quiet --exit-code 2>/dev/null || unset changes
	if ! $(git rev-parse --quiet --verify HEAD >/dev/null && 
			git diff-index --cached --quiet HEAD --)
	then
		unset changes
	fi
	if [ $changes ]
	then
		echo "No changes found."
		echo "If you have untracked files, add them first using git add."
		return $STASHERROR
	fi
	if ! git stash
	then
		echo "Stash failed. Exiting."
		return $STASHERROR
	fi

	git checkout ${upstream}
	if [ "$upstream" != "$(git branch 2>/dev/null | grep '*' | sed 's/* \(.*\)/\1/')" ]
	then
		echo "Failed to check out ${upstream} branch.\n"
		echo "Returning to branch ${thisbranch} and exiting.\n"
		echo "Not re-applying stash to avoid data loss."
		git checkout ${thisbranch} 2>/dev/null
		return $BRANCHERROR
	fi

	# if username and email aren't set, set them to the upstream config settings
	[ -n "$username" ] || username="$localuser"
	[ -n "$usermail" ] || usermail="$localmail"
	# set up author string for commit. author string is of the form
	# "--author='username <email>'" if both exist. If username exists but not
	# email, it's "--author='email'". If neither exist, it is blank.
	if [ -n "$username" ]; then
		if [ -n "$usermail" ]; then
			authorstring="${username} <${usermail}>"
		else
			authorstring="${username}"
			echo "WARNING: Could not determine user email"
		fi
	else
		echo "WARNING: Could not determine user name"
		if [ -n "$usermail" ]; then
			authorstring="${usermail}"
		else
			echo "WARNING: Could not determine user email"
			# no user or email, unset --author flag
			authflag=''
		fi
	fi

	if [ $PULL -eq 1 ]; then
		if ! git pull ${remote} ${upstream}
		then
			echo "Problem pulling from ${remote}. Exiting."
			return $REMOTEERROR
		fi
	fi

    # apply the changes
	if ! git stash apply
	then
		echo "Problem applying stash. Exiting."
		return $STASHERROR
	fi

	if [ -n "$@" ]; then # specific files
		git add $@
	else # no files supplied, add everything
		git add .
	fi

	if ! git commit $authflag "${authorstring}" $msgflag "${message}"
	then
		echo "Commit failed or was aborted. Exiting."
		return $COMMITERROR
	fi

    # Push changes to the origin
	if [ $remote != '--' ]; then
		git push ${remote} ${upstream}
	fi

	# Remove changes in case we didn't commit the whole directory
	git reset HEAD
	git checkout --

    # back to the original branch
	git checkout ${thisbranch}
	if [ "$thisbranch" != "$(git branch 2>/dev/null | grep '*' | sed 's/* \(.*\)/\1/')" ]
	then
		echo "Failed to return to branch ${thisbranch}. Exiting.\n"
		echo "Keeping stash to avoid data loss."
		return $BRANCHERROR
	fi

    # Now rebase
	if [ $REBASE -eq 0 ]; then
		if ! git rebase master
		then
			echo "Rebase had errors. Exiting.\n"
			echo "Keeping stash to avoid data loss."
			return $CONFLICTS
		fi
	else
		echo "--norebase option set, skipping rebase."
	fi

	if [ -n "$@" ]; then # files supplied
		if ! git stash apply
		then
			echo "Problem re-applying stash. Exiting."
			return $STASHERROR
		fi
		echo "Re-applying uncommitted changes."
	fi
	if [ $CLEAR -eq 0]; then
		git stash drop # removes top stash
	else
		echo "--noclear option set, keeping stash."
	fi

	echo "Re-scope complete."
	return $SUCCESS
}
