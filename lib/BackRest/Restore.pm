####################################################################################################################################
# RESTORE MODULE
####################################################################################################################################
package BackRest::Restore;

use threads;
use threads::shared;
use Thread::Queue;
use strict;
use warnings;
use Carp;

use File::Basename;

use lib dirname($0);
use BackRest::Utility;
use BackRest::ThreadGroup;
use BackRest::Config;
use BackRest::File;

####################################################################################################################################
# CONSTRUCTOR
####################################################################################################################################
sub new
{
    my $class = shift;              # Class name
    my $strDbClusterPath = shift;   # Database cluster path
    my $strBackupPath = shift;      # Backup to restore
    my $oRemapRef = shift;          # Tablespace remaps
    my $oFile = shift;              # Default file object
    my $iThreadTotal = shift;       # Total threads to run for restore
    my $bForce = shift;             # Force the restore even if files are present

    # Create the class hash
    my $self = {};
    bless $self, $class;

    # Initialize variables
    $self->{strDbClusterPath} = $strDbClusterPath;
    $self->{oFile} = $oFile;
    $self->{iThreadTotal} = defined($iThreadTotal) ? $iThreadTotal : 1;
    $self->{bForce} = $bForce;
    $self->{oRemapRef} = $oRemapRef;

    # If backup path is not specified then default to latest
    if (defined($strBackupPath))
    {
        $self->{strBackupPath} = $strBackupPath;
    }
    else
    {
        $self->{strBackupPath} = PATH_LATEST;
    }

    return $self;
}

####################################################################################################################################
# MANIFEST_OWNERSHIP_TEST
#
# Checks the users and groups that exist in the manifest and emits warnings for ownership that cannot be set properly, either
# because the current user does not have permissions or because the user/group does not exist.
####################################################################################################################################
sub manifest_ownership_test
{
    my $self = shift;               # Class hash
    my $oManifestRef = shift;       # Backup manifest

    # Create hashes to track valid/invalid users/groups
    my %oOwnerHash = ();

    # Create hash for each type and owner to be checked
    my $strDefaultUser = getpwuid($<);
    my $strDefaultGroup = getgrgid($();

    my %oFileTypeHash = ('path' => true, 'link' => true, 'file' => true);
    my %oOwnerTypeHash = ('user' => $strDefaultUser, 'group' => $strDefaultGroup);

    # Loop through owner types
    foreach my $strOwnerType (sort (keys %oOwnerTypeHash))
    {
        # Loop through all backup paths
        foreach my $strPathKey (sort(keys ${$oManifestRef}{'backup:path'}))
        {
            # Loop through types
            foreach my $strFileType (sort (keys %oFileTypeHash))
            {
                # Get users and groups for paths
                foreach my $strName (sort (keys ${$oManifestRef}{"${strPathKey}:${strFileType}"}))
                {
                    my $strOwner = ${$oManifestRef}{"${strPathKey}:${strFileType}"}{$strName}{$strOwnerType};

                    # If root then test to see if the user/group is valid
                    if ($< == 0)
                    {
                        # If the owner has not been tested yet then test it
                        if (!defined($oOwnerHash{$strOwnerType}{$strOwner}))
                        {
                            $oOwnerHash{$strOwnerType}{$strOwner} = ($strOwnerType eq 'user' && defined(getpwnam($strOwner))) ||
                                                                    ($strOwnerType eq 'group' && defined(getpwnam($strOwner)));
                        }

                        if (!$oOwnerHash{$strOwnerType}{$strOwner})
                        {
                            ${$oManifestRef}{"${strPathKey}:${strFileType}"}{$strName}{$strOwnerType} =
                                $oOwnerTypeHash{$strOwnerType};
                        }
                    }
                    # Else set user/group to current user/group
                    else
                    {
                        if ($strOwner ne $oOwnerTypeHash{$strOwnerType})
                        {
                            $oOwnerHash{$strOwnerType}{$strOwner} = false;
                            ${$oManifestRef}{"${strPathKey}:${strFileType}"}{$strName}{$strOwnerType} =
                                $oOwnerTypeHash{$strOwnerType};
                        }
                    }
                }
            }
        }

        # Output warning for any invalid owners
        foreach my $strOwner (sort (keys $oOwnerHash{$strOwnerType}))
        {
            &log(WARN, "${strOwnerType} ${strOwner} " . ($< == 0 ? "does not exist" : "cannot be set") .
                       ", changed to $oOwnerTypeHash{$strOwnerType}");
        }
    }
}

####################################################################################################################################
# MANIFEST_LOAD
#
# Loads the backup manifest and performs requested tablespace remaps.
####################################################################################################################################
sub manifest_load
{
    my $self = shift;           # Class hash
    my $oManifestRef = shift;   # Backup manifest

    if ($self->{oFile}->exists(PATH_BACKUP_CLUSTER, $self->{strBackupPath}))
    {
        # Copy the backup manifest to the db cluster path
        $self->{oFile}->copy(PATH_BACKUP_CLUSTER, $self->{strBackupPath} . '/' . FILE_MANIFEST,
                             PATH_DB_ABSOLUTE, $self->{strDbClusterPath} . '/' . FILE_MANIFEST);

        # Load the manifest into a hash
        ini_load($self->{oFile}->path_get(PATH_DB_ABSOLUTE, $self->{strDbClusterPath} . '/' . FILE_MANIFEST), $oManifestRef);

        # Remove the manifest now that it is in memory
        $self->{oFile}->remove(PATH_DB_ABSOLUTE, $self->{strDbClusterPath} . '/' . FILE_MANIFEST);
        
        # If backup is latest then set it equal to backup label, else verify that requested backup and label match
        if ($self->{strBackupPath} eq PATH_LATEST)
        {
            $self->{strBackupPath} = ${$oManifestRef}{'backup'}{label};
        }
        elsif ($self->{strBackupPath} ne ${$oManifestRef}{'backup'}{label})
        {
            confess &log(ASSERT, "request backup $self->{strBackupPath} and label ${$oManifestRef}{'backup'}{label} do not match " .
                                 " - this indicates some sort of corruption (at the very least paths have been renamed.");
        }

        # If tablespaces have been remapped, update the manifest
        if (defined($self->{oRemapRef}))
        {
            foreach my $strPathKey (sort(keys $self->{oRemapRef}))
            {
                my $strRemapPath = ${$self->{oRemapRef}}{$strPathKey};

                if ($strPathKey eq 'base')
                {
                    &log(INFO, "remapping base to ${strRemapPath}");
                    ${$oManifestRef}{'backup:path'}{$strPathKey} = $strRemapPath;
                }
                else
                {
                    # If the tablespace beigns with prefix 'tablespace:' then strip the prefix.  This only needs to be used in
                    # the case that there is a tablespace called 'base'
                    if (index($strPathKey, 'tablespace:') == 0)
                    {
                        $strPathKey = substr($strPathKey, length('tablespace:'));
                    }

                    # Make sure that the tablespace exists in the manifest
                    if (!defined(${$oManifestRef}{'backup:tablespace'}{$strPathKey}))
                    {
                        confess &log(ERROR, "cannot remap invalid tablespace ${strPathKey} to ${strRemapPath}");
                    }

                    # Remap the tablespace in the manifest
                    &log(INFO, "remapping tablespace to ${strRemapPath}");

                    my $strTablespaceLink = ${$oManifestRef}{'backup:tablespace'}{$strPathKey}{link};

                    ${$oManifestRef}{'backup:path'}{"tablespace:${strPathKey}"} = $strRemapPath;
                    ${$oManifestRef}{'backup:tablespace'}{$strPathKey}{path} = $strRemapPath;
                    ${$oManifestRef}{'base:link'}{"pg_tblspc/${strTablespaceLink}"}{link_destination} = $strRemapPath;
                }
            }
        }
    }
    else
    {
        confess &log(ERROR, 'backup ' . $self->{strBackupPath} . ' does not exist');
    }

    $self->manifest_ownership_test($oManifestRef);
}

####################################################################################################################################
# CLEAN
#
# Checks that the restore paths are empty, or if --force was used then it cleans files/paths/links from the restore directories that
# are not present in the manifest.
####################################################################################################################################
sub clean
{
    my $self = shift;               # Class hash
    my $oManifestRef = shift;       # Backup manifest

    # Check each restore directory in the manifest and make sure that it exists and is empty.
    # The --force option can be used to override the empty requirement.
    foreach my $strPathKey (sort(keys ${$oManifestRef}{'backup:path'}))
    {
        my $strPath = ${$oManifestRef}{'backup:path'}{$strPathKey};

        &log(INFO, "checking/cleaning db path ${strPath}");

        if (!$self->{oFile}->exists(PATH_DB_ABSOLUTE,  $strPath))
        {
            confess &log(ERROR, "required db path '${strPath}' does not exist");
        }

        # Load path manifest so it can be compared to deleted files/paths/links that are not in the backup
        my %oPathManifest;
        $self->{oFile}->manifest(PATH_DB_ABSOLUTE, $strPath, \%oPathManifest);

        foreach my $strName (sort {$b cmp $a} (keys $oPathManifest{name}))
        {
            # Skip the root path
            if ($strName eq '.')
            {
                next;
            }

            # If force was not specified then error if any file is found
            if (!$self->{bForce})
            {
                confess &log(ERROR, "db path '${strPath}' contains files");
            }

            my $strFile = "${strPath}/${strName}";

            # Determine the file/path/link type
            my $strType = 'file';

            if ($oPathManifest{name}{$strName}{type} eq 'd')
            {
                $strType = 'path';
            }
            elsif ($oPathManifest{name}{$strName}{type} eq 'l')
            {
                $strType = 'link';
            }

            # Check to see if the file/path/link exists in the manifest
            if (defined(${$oManifestRef}{"${strPathKey}:${strType}"}{$strName}))
            {
                my $strMode = ${$oManifestRef}{"${strPathKey}:${strType}"}{$strName}{permission};

                # If file/path mode does not match, fix it
                if ($strType ne 'link' && $strMode ne $oPathManifest{name}{$strName}{permission})
                {
                    &log(DEBUG, "setting ${strFile} mode to ${strMode}");

                    chmod(oct($strMode), $strFile)
                        or confess 'unable to set mode ${strMode} for ${strFile}';
                }

                my $strUser = ${$oManifestRef}{"${strPathKey}:${strType}"}{$strName}{user};
                my $strGroup = ${$oManifestRef}{"${strPathKey}:${strType}"}{$strName}{group};

                # If ownership does not match, fix it
                if ($strUser ne $oPathManifest{name}{$strName}{user} ||
                    $strGroup ne $oPathManifest{name}{$strName}{group})
                {
                    &log(DEBUG, "setting ${strFile} ownership to ${strUser}:${strGroup}");

                    # !!! Need to decide if it makes sense to set the user to anything other than the db owner
                }

                # If a link does not have the same destination, then delete it (it will be recreated later)
                if ($strType eq 'link' && ${$oManifestRef}{"${strPathKey}:${strType}"}{$strName}{link_destination} ne
                    $oPathManifest{name}{$strName}{link_destination})
                {
                    &log(DEBUG, "removing link ${strFile} - destination changed");
                    unlink($strFile) or confess &log(ERROR, "unable to delete file ${strFile}");
                }
            }
            # If it does not then remove it
            else
            {
                # If a path then remove it, all the files should have already been deleted since we are going in reverse order
                if ($strType eq 'path')
                {
                    &log(DEBUG, "removing path ${strFile}");
                    rmdir($strFile) or confess &log(ERROR, "unable to delete path ${strFile}, is it empty?");
                }
                # Else delete a file/link
                else
                {
                    &log(DEBUG, "removing file/link ${strFile}");
                    unlink($strFile) or confess &log(ERROR, "unable to delete file/link ${strFile}");
                }
            }
        }
    }
}

####################################################################################################################################
# BUILD
#
# Creates missing paths and links and corrects ownership/mode on existing paths and links.
####################################################################################################################################
sub build
{
    my $self = shift;               # Class hash
    my $oManifestRef = shift;       # Backup manifest

    # Build paths/links in each restore path
    foreach my $strPathKey (sort(keys ${$oManifestRef}{'backup:path'}))
    {
        my $strPath = ${$oManifestRef}{'backup:path'}{$strPathKey};

        # Create all paths in the manifest that do not already exist
        foreach my $strName (sort (keys ${$oManifestRef}{"${strPathKey}:path"}))
        {
            # Skip the root path
            if ($strName eq '.')
            {
                next;
            }

            # Create the Path
            if (!$self->{oFile}->exists(PATH_DB_ABSOLUTE, "${strPath}/${strName}"))
            {
                $self->{oFile}->path_create(PATH_DB_ABSOLUTE, "${strPath}/${strName}",
                                            ${$oManifestRef}{"${strPathKey}:path"}{$strName}{permission});
            }
        }

        # Create all links in the manifest that do not already exist
        if (defined(${$oManifestRef}{"${strPathKey}:link"}))
        {
            foreach my $strName (sort (keys ${$oManifestRef}{"${strPathKey}:link"}))
            {
                if (!$self->{oFile}->exists(PATH_DB_ABSOLUTE, "${strPath}/${strName}"))
                {
                    $self->{oFile}->link_create(PATH_DB_ABSOLUTE,
                                                ${$oManifestRef}{"${strPathKey}:link"}{$strName}{link_destination},
                                                PATH_DB_ABSOLUTE, "${strPath}/${strName}");
                }
            }
        }
    }
}

####################################################################################################################################
# RESTORE
#
# Takes a backup and restores it back to the original or a remapped location.
####################################################################################################################################
sub restore
{
    my $self = shift;       # Class hash

    # Make sure that Postgres is not running
    if ($self->{oFile}->exists(PATH_DB_ABSOLUTE, $self->{strDbClusterPath} . '/' . FILE_POSTMASTER_PID))
    {
        confess &log(ERROR, 'unable to restore while Postgres is running');
    }

    # Log the backup set to restore
    &log(INFO, "Restoring backup set " . $self->{strBackupPath});

    # Make sure the backup path is valid and load the manifest
    my %oManifest;
    $self->manifest_load(\%oManifest);

    # Clean the restore paths
    $self->clean(\%oManifest);

    # Build paths/links in the restore paths
    $self->build(\%oManifest);

    # Assign the files in each path to a thread queue
    my @oyRestoreQueue;

    foreach my $strPathKey (sort(keys $oManifest{'backup:path'}))
    {
        if (defined($oManifest{"${strPathKey}:file"}))
        {
            $oyRestoreQueue[@oyRestoreQueue] = Thread::Queue->new();

            foreach my $strName (sort (keys $oManifest{"${strPathKey}:file"}))
            {
                $oyRestoreQueue[@oyRestoreQueue - 1]->enqueue("${strPathKey}|${strName}");
            }

            $oyRestoreQueue[@oyRestoreQueue - 1]->end();
        }
    }

    # Create threads to process the thread queues
    my $oThreadGroup = new BackRest::ThreadGroup();

    for (my $iThreadIdx = 0; $iThreadIdx < $self->{iThreadTotal}; $iThreadIdx++)
    {
        $oThreadGroup->add(threads->create(\&restore_thread, $self, $iThreadIdx, \@oyRestoreQueue, \%oManifest));
    }

    $oThreadGroup->complete();
}

####################################################################################################################################
# RESTORE_THREAD
#
# Worker threads for the restore process.
####################################################################################################################################
sub restore_thread
{
    my $self = shift;               # Class hash
    my $iThreadIdx = shift;         # Defines the index of this thread
    my $oyRestoreQueueRef = shift;  # Restore queues
    my $oManifestRef = shift;       # Backup manifest

    my $iDirection = $iThreadIdx % 2 == 0 ? 1 : -1;         # Size of files currently copied by this thread
    my $oFileThread = $self->{oFile}->clone($iThreadIdx);   # Thread local file object

    # Initialize the starting and current queue index based in the total number of threads in relation to this thread
    my $iQueueStartIdx = int((@{$oyRestoreQueueRef} / $self->{iThreadTotal}) * $iThreadIdx);
    my $iQueueIdx = $iQueueStartIdx;

    # Set source compression
    my $bSourceCompression = ${$oManifestRef}{'backup:option'}{compress} eq 'y' ? true : false;

    # When a KILL signal is received, immediately abort
    $SIG{'KILL'} = sub {threads->exit();};

    # Get the current user and group to compare with stored permissions
    my $strCurrentUser = getpwuid($<);
    my $strCurrentGroup = getgrgid($();

    # Loop through all the queues to restore files (exit when the original queue is reached
    do
    {
        while (my $strMessage = ${$oyRestoreQueueRef}[$iQueueIdx]->dequeue())
        {
            my $strSourcePath = (split(/\|/, $strMessage))[0];                        # Source path from backup
            my $strSection = "${strSourcePath}:file";                                 # Backup section with file info
            my $strDestinationPath = ${$oManifestRef}{'backup:path'}{$strSourcePath}; # Destination path stored in manifest
            $strSourcePath =~ s/\:/\//g;                                              # Replace : with / in source path
            my $strName = (split(/\|/, $strMessage))[1];                              # Name of file to be restored

            # If the file is a reference to a previous backup and hardlinks are off, then fetch it from that backup
            my $strReference = ${$oManifestRef}{'backup:option'}{hardlink} eq 'y' ? undef :
                                   ${$oManifestRef}{$strSection}{$strName}{reference};

            # Generate destination file name
            my $strDestinationFile = $oFileThread->path_get(PATH_DB_ABSOLUTE, "${strDestinationPath}/${strName}");

            # If checksum is set the destination file already exists, try a checksum before copying
            my $strChecksum = ${$oManifestRef}{$strSection}{$strName}{checksum};

            if ($oFileThread->exists(PATH_DB_ABSOLUTE, $strDestinationFile))
            {
                if (defined($strChecksum) && $oFileThread->hash(PATH_DB_ABSOLUTE, $strDestinationFile) eq $strChecksum)
                {
                    &log(DEBUG, "${strDestinationFile} exists and matches backup checksum ${strChecksum}");
                    next;
                }

                $oFileThread->remove(PATH_DB_ABSOLUTE, $strDestinationFile);
            }

            # Set user and group if running as root (otherwise current user and group will be used for restore)
            my $strUser = undef;
            my $strGroup = undef;

            if ($< == 0)
            {
                $strUser = ${$oManifestRef}{$strSection}{$strName}{user};

                if (!defined(getpwnam($strUser)))
                {
                    $strUser = $strCurrentUser;
                }

                $strGroup = ${$oManifestRef}{$strSection}{$strName}{group};

                if (!defined(getgrnam($strGroup)))
                {
                    $strGroup = $strCurrentGroup;
                }
            }

            # Copy the file from the backup to the database
            $oFileThread->copy(PATH_BACKUP_CLUSTER, (defined($strReference) ? $strReference : $self->{strBackupPath}) .
                               "/${strSourcePath}/${strName}" .
                               ($bSourceCompression ? '.' . $oFileThread->{strCompressExtension} : ''),
                               PATH_DB_ABSOLUTE, $strDestinationFile,
                               $bSourceCompression,   # Source is compressed based on backup settings
                               undef, undef,
                               ${$oManifestRef}{$strSection}{$strName}{modification_time},
                               ${$oManifestRef}{$strSection}{$strName}{permission},
                               $strUser, $strGroup);
        }

        # Even number threads move up when they have finished a queue, odd numbered threads move down
        $iQueueIdx += $iDirection;

        # Reset the queue index when it goes over or under the number of queues
        if ($iQueueIdx < 0)
        {
            $iQueueIdx = @{$oyRestoreQueueRef} - 1;
        }
        elsif ($iQueueIdx >= @{$oyRestoreQueueRef})
        {
            $iQueueIdx = 0;
        }
    }
    while ($iQueueIdx != $iQueueStartIdx);

    &log(DEBUG, "thread ${iThreadIdx} exiting");
}

1;
