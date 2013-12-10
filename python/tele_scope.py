#!python

import argparse, git, sys, os

class BranchError(StandardError):
    def __init__(self, message):
        super(BranchError, self).__init(message)

class StashError(StandardError):
    def __init__(self, message):
        super(StashError, self).__init__(message)

class CommitError(StandardError):
    def __init__(self, message):
        super(CommitError, self).__init__(message)

class RemoteError(StandardError):
    def __init__(self, message):
        super(RemoteError, self).__init__(message)

class ConflictError(StandardError):
    def __init__(self, message):
        super(ConflictError, self).__init__(message)

class ExitStatus:
    """exit statuses for the tele-scope script"""
    SUCCESS, BRANCHERROR, STASHERROR, COMMITERROR, REMOTERROR, CONFLICTS = range(6)
    
class TeleScope:
    """Move files from the current (local) changeset to an upstream branch:
    1) stashes changeset and moves upstream to apply it
    2) commits changeset and pushes to the remote origin
    3) returns to local branch and rebases onto the upstream branch
    TeleScope(files=['.'], upstream='master', remote='origin',
              user=None, email=None, message=None,
              norebase=False, noclear=False, pull=False)
    If no files are specified, all changes are moved. If files are
    specified, the stash will be re-applied after rebasing.

    options:
    upstream:      Use argument as <upstream> for rebasing.
    remote:        Use argument as the remote repository.
                   If this argument is None, or doesn't exist
                   as a remote, changes will not be pushed.
    user:          Use argument as user.name.
    email:         Use argument as user.email.
    message:       Use argument as commit message.
    norebase=True: Return to the local branch, but do not rebase.
    noclear=True:  Do not remove the stashed changes. By default,
                   the stash will be removed after rebasing.
    pull=True:     Pull from the remote repo before committing.

    user.name and user.email default to the repository settings;
    if these do not exist, global options are used."""

    def __init__(self, repo, upstream='master', remote='origin',
                 user=None, email=None, message=None,
                 norebase=False, noclear=False, pull=False):

        if repo.__class__ != git.Repo:
            raise TypeError("'repo' must be a Git repository object.")

        self.repo = repo
        # get important info from local branch
        self.thisbranch=self.repo.active_branch.name
        self.upstream = upstream
        self.remote = remote

        reader=repo.config_reader()
        self.user = self.getOption(reader, 'user.name', user)
        self.email = self.getOption(reader, 'user.email', email)

        self.message = message
        self.norebase = norebase
        self.noclear = noclear
        self.reapply = False # need to reapply stash after rebase?
        self.pull = pull

    def getOption(self, reader, name, value):
        section, option = name.split('.')
        if value == None and reader.has_option(section, option):
            value = reader.get_value(section, option)
        return value

    def stashChanges(self):
    # Don't bother checking for changes, just stash and trap errors
        try:
            result=self.repo.git.stash()
        except git.GitCommandError as ex:
            raise StashError(ex.message)
        else:
            if result=='No local changes to save':
                raise StashError(result)

    def switchBranch(self, branch):
        branches = self.repo.heads
        try:
            branches[branch].checkout()
        except IndexError: # no branch with that name
            raise BranchError('Branch {0} not found.'.format(branch))
        except TypeError:
            raise BranchError('branch argument should be a string.')
        except git.GitCommandError as ex:
            raise BranchError(ex.message)

    def pullFromRemote(self):
        remotes = self.repo.remotes
        try:
            remotes[self.remote].pull()
        except IndexError: # no remote with that name
            raise RemoteError('Remote {0} not found'.format(self.remote))
        except Exception as ex:
            raise RemoteError('Problem with pull:\n{0}'.format(ex.message))
            

    def applyChanges(self, files=None):
        # Assume we are still downstream
        try:
            self.switchBranch(self.upstream)
        except:
            raise
        # apply the changes
        try:
            result=self.repo.git.stash('apply')
        except git.GitCommandError as ex:
            raise StashError(ex.message)
        # How best to add the files?

        if files is None:
            files=[self.repo.working_dir]
        else:
            self.reapply=True

        # Should really be using the Index object to add and commit
        try:
            for newfile in files:
                self.repo.git.add(os.path.abspath(newfile))
        except git.GitCommandError as ex:
            raise CommitError(ex.message)

        if self.email is None:
            authorstring=self.user
        elif self.user is None:
            authorstring=self.email
        else:
            authorstring='{0} <{1}>'.format(self.user, self.email)

        try:
            self.repo.git.commit(author=authorstring, message=self.message)
        except git.GitCommandError as ex:
            raise CommitError(ex.message)

        # Push changes to the origin
	if self.remote is not None:
            try:
                result=self.remote.push()
            except git.GitCommandError as ex:
                raise RemoteError('Problem with push:\n{0}'.format(ex.message))

        if self.reapply:
            self.backoutChanges()

    def backoutChanges(self):
        self.repo.head.reset() # unstage any staged changes
        self.active_branch.checkout(force=True) # discard any unstaged changes

    def switchAndRebase(self):
        # back to the original branch
        try:
            self.switchBranch(self.thisbranch)
        except:
            raise

        # Now rebase
        if self.norebase:
            sys.stderr.write("--norebase option set, skipping rebase.")
        else:
            try:
                self.repo.git.rebase(self.upstream)
            except git.GitCommandError as ex:
                raise ConflictError('Problem in rebase:\n{0}'.format(ex.message))

        # and drop the stash
        if self.noclear:
            sys.stderr.write("--noclear option set, keeping stash.")
        else:
            self.repo.git.stash('drop')

if __name__ == '__main__':
    status=ExitStatus()

    intro="""Move files from the current (local) changeset to an upstream branch:
    1) stashes changeset and moves upstream to apply it
    2) commits changeset and pushes to the remote origin
    3) returns to local branch and rebases onto the upstream branch"""

    warning="""This script comes with the following caveats and warnings:
  - If your current branch is part of a public repository, think very
    carefully about whether you want to rebase. If just the master
    is part of a public repository, it's far less likely that you'll
    cause trouble, but make sure you're up-to-date if
    you're worried that other people have been pushing to that branch.
  - This script does NOT merge after rebasing. It is assumed that if you 
    wanted to do that, you wouldn't bother stashing changes; you'd just
    commit, rebase, and merge. The idea of this script is that you have
    some (previously committed) changes on the current branch that you
    don't want on master.
  - If there is a problem at any step, the script will attempt to back out
    any changes. The stash will not be deleted until the changes are
    committed and pushed, and the current branch has been rebased."""

    parser=argparse.ArgumentParser(prog=sys.argv[0], \
                                       formatter_class=argparse.RawDescriptionHelpFormatter, \
                                       usage='%(prog)s [OPTIONS] [FILES]', \
                                       description=intro, \
                                       epilog=warning)
    parser.add_argument("-b","--norebase", \
                            help="Return to the local branch, but do not rebase.", \
                            action="store_true")
    parser.add_argument("-c","--noclear", \
                            help="Do not remove the stashed changes. By default, the stash will be removed after rebasing.", \
                            action="store_true")
    parser.add_argument("-e","--email", \
                            help="Use next argument as user.email.")
    parser.add_argument("-m","--message", \
                            help="Use next (quoted) argument as commit message.")
    parser.add_argument("-n","--branch", default='master', \
                            help="Use next argument as <upstream> for rebasing. Default is master.")
    parser.add_argument("-p","--pull", \
                            help="Pull from the remote repo before commiting.", \
                            action="store_true")
    parser.add_argument("-r","--remote", default='origin', \
                            help="Use the next argument as the remote repository. Default is origin. If this argument is 'None', do not push changes.")
    parser.add_argument("-u","--user", \
                            help="Use next argument as user.name (put in quotes).")
    parser.add_argument("files", nargs='*', \
                            help="Files/directories to commit to upstream. If no files are specified, all changes in the current working tree will be moved. Any changes not commited upstream will be re-applied after rebasing.")

    here = os.getcwd()
    try:
        # try to find a repo in the current directory
        repo = git.Repo(here)
    except git.InvalidGitRepositoryError:
        sys.stderr.write("You must be inside a git repository to run tele-scope.\n")
        sys.exit(status.BRANCHERROR)

    #Get the arguments from the command line
    args = parser.parse_args()
    tsRemote = None
    if args.remote.lower() != 'none':
        try:
            tsRemote=repo.remotes[args.remote]
        except IndexError:
            sys.stderr.write('No remote {0} found.\n'.format(args.remote))
            sys.stderr.write('To run without remote, use "-r None"\n')
            sys.exit(status.REMOTERROR)

    try:
        scoper=TeleScope(repo, args.branch, tsRemote, \
                             args.user, args.email, args.message, \
                             args.norebase, args.noclear, args.pull)
        scoper.stashChanges()
        scoper.applyChanges(args.files)
        scoper.switchAndRebase()
    except Exception as ex:
        sys.stderr.write(ex.message)
    else:
        print("Re-scope complete.")
        sys.exit(status.SUCCESS)
