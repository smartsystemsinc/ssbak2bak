#!/usr/bin/env perl

# Force me to write this properly

use strict;
use warnings;

# Modules

use Carp;              # Built-in
use Config::Simple;    # dpkg libconfig-simple-perl || cpan Config::Simple
use English qw(-no_match_vars);                 # Built-in
use Fcntl ':flock';                             # Built-in
use Getopt::Long qw(:config no_ignore_case);    # Built-in
use POSIX qw(strftime);                         # Built-in
use Pod::Usage;                                 # Built-in
use feature 'say';
use sigtrap qw/handler cleanup normal-signals/;

our $VERSION = '0.3';

INIT {
    if ( !flock main::DATA, LOCK_EX | LOCK_NB ) {
        my @emails;
        my $cur_time = strftime '%c', localtime;
        my $mail_bin = `which mail`;
        if ( $mail_bin eq q{} ) {
            say
                "heirloom-mailx is not installed and $PROGRAM_NAME is already running"
                or croak $ERRNO;
            exit 1;
        }
        else {
            chomp $mail_bin;
        }

        # Try to read in parameters from the config file
        my $base_dir = $ENV{'HOME'} . '/.local/share/SS/ssbak2bak';
        my $config   = "$base_dir/config.ini";
        if ( -f "$config" ) {
            my $cfg = Config::Simple->new();
            $cfg->read("$config") or croak $ERRNO;
            @emails = $cfg->param('emails');

            # Override parameters if entered on the command line
            GetOptions( 'emails|e:s{,}' => \@emails, );
            say "$PROGRAM_NAME is already running" or croak $ERRNO;
            if (@emails) {
                my $email_output = "$PROGRAM_NAME is already running";
                my $email_subject
                    = "UVB: Error report from $PROGRAM_NAME at $cur_time";
                ### $email_output
                my @command = ( "$mail_bin", '-s', $email_subject, @emails );
                open my $mail, q{|-}, @command or croak $ERRNO;
                printf {$mail} "%s\n", $email_output;
                close $mail or croak $ERRNO;
            }
            else {
                carp "No e-mail defined -- user cannot be notified\n";
            }
            exit 1;
        }
    }
}

## no critic (RequireLocalizedPunctuationVars)
BEGIN {
    $ENV{Smart_Comments} = " @ARGV " =~ /--debug/xms;
}
use Smart::Comments -ENV
    ;    # dpkg libsmart-comments-perl || cpan Smart::Comments

# Set variables
my $backup_to;
my $base_device;
my $base_dir = $ENV{'HOME'} . '/.local/share/SS/ssbak2bak';
my $config   = "$base_dir/config.ini";
my $email_subject;
my $email_output;
my $mail_bin;    # Defined in check_external_programs();
my $pid;         # For rsync
my $real_device;
my $real_device_base;
my $rsync;       # Defined in check_external_programs();
my $rsync_log = "$base_dir/rsync.log";
my $rsync_options
    = " --archive --hard-links --acls --xattrs --verbose --log-file=$rsync_log";
my $rsync_output;
my $rsync_start_time;
my $rsync_status_return;
my $rsync_stop_time;
my $source_dir;
my $start = time;
my $symlink;
my @allowed_uuids;
my @emails;
my @symlinks;

# Ensure directory exists
if ( !-d $base_dir ) { system "mkdir -p $base_dir" and croak $ERRNO; }

# Try to read in parameters from the config file
if ( -f "$config" ) {
    my $cfg = Config::Simple->new();
    $cfg->read("$config") or croak $ERRNO;
    @emails        = $cfg->param('emails');
    $source_dir    = $cfg->param('source');
    @allowed_uuids = $cfg->param('allowed_uuids');
}

# Override parameters if entered on the command line
GetOptions(
    'help|h'        => \my $help,
    'debug'         => \my $debug,            # dummy variable
    'man'           => \my $man,
    'version|v'     => \my $version,
    'emails|e:s{,}' => \@emails,
    'source|s:s'    => \$source_dir,
    'uuids|u:s{,}'  => \my @allowed_uuids2,

) or pod2usage( -verbose => 0 );

if ($help) {
    pod2usage( -verbose => 0 );
}
if ($man) {
    pod2usage( -verbose => 2 );
}
if ($version) {
    die "$PROGRAM_NAME v$VERSION\n";
}

# Necessary to clear the array so that uuids from the INI and the argument don't mix
if (@allowed_uuids2) {
    @allowed_uuids = @allowed_uuids2;
}

if ( $EFFECTIVE_USER_ID != 0 ) {
    die "This script can only run as root\n";
}

# Verify that e-mail and source dirs make reasonable sense
foreach (@emails) {
    if ( !m/^\w+[@][\d[:alpha:]\-]{1,}[.]{1,}[\d[:alpha:]-]{2,6}$/xms ) {
        croak "Invalid e-mail address syntax in $_\n";
    }
}
if ( !-d $source_dir ) {
    croak "Source directory $source_dir doesn't exist\n";
}

# Verify that we have a list of acceptable UUIDs
if ( !scalar @allowed_uuids ) {
    croak "Missing list of acceptable UUIDs\n";
}

# Verify that non-core external programs are installed
check_external_programs();

# Get symlinks
get_symlinks();
### @symlinks

# Run the main program; if @symlinks is empty then exit
LOOP:
if (@symlinks) {
    foreach (@symlinks) {
        main($_);
    }
}
else {
    say 'Finished' or croak $ERRNO;
    exit;
}

# Get a new list of symlinks
get_symlinks();

goto LOOP;

# Subprocedures

sub main {

    $symlink = shift or croak "Missing paramter - safety symlink\n";
    chomp $symlink;
    ### $symlink
    # Base device should be e.g. 'sda' or 'xvda'
    ($base_device) = ( $symlink =~ /( (sd|xvd)[[:lower:]])/xms );
    ### $base_device
    # Real device should be e.g. /sys/block/sda but need to make sure
    $real_device_base = `readlink /sys/block/$base_device`;
    chomp $real_device_base;
    ### $real_device_base
    ($real_device)
        = ( $real_device_base =~ /( \/block\/(sd|xvd)[[:lower:]])/xms );
    $real_device = '/sys' . $real_device;
    chomp $real_device;
    ### $real_device

    verify();

    backup();

    return 0;
}

sub check_external_programs {

    $rsync = `which rsync`;
    if ( $rsync eq q{} ) {
        say 'rsync not found. Attempting to install.' or croak $ERRNO;
        system 'apt-get install rsync --yes' and croak $ERRNO;
    }
    else {
        chomp $rsync;
        $rsync = $rsync . $rsync_options;
        ### rsync
        ### $rsync_options
    }

    $mail_bin = `which mail`;
    if ( $mail_bin eq q{} ) {
        say 'heirloom-mailx not found. Attempting to install.'
            or croak $ERRNO;
        system 'apt-get install heirloom-mailx --yes'
            and croak $ERRNO;
    }
    else {
        chomp $mail_bin;
    }
    if ( !-f $ENV{'HOME'} . '/.mailrc' ) {
        croak "Local mailrc file not found.\n";
    }

    if ( `which msmtp` eq q{} ) {
        say 'msmtp not found. Attempting to install.' or croak $ERRNO;
        system 'apt-get install msmtp --yes' and croak $ERRNO;
    }
    if ( !-f $ENV{'HOME'} . '/.msmtprc' ) {
        croak "Local msmtprc file not found.\n";
    }

    return 0;
}

sub get_symlinks {

    # In this case, we only want the first partition
    opendir DIR, '/dev' or croak $ERRNO;
    @symlinks = grep {/safety(sd|xvd)[[:lower:]][1]/xms} readdir DIR;
    @symlinks = sort @symlinks;
    closedir DIR or croak $ERRNO;
    return 0;
}

sub verify {
    if (   !is_permitted() == 0
        || !is_large_enough() == 0
        || !has_free_space() == 0 )
    {
        system "rm /dev/$symlink" and croak $ERRNO;
        say
            'Disk is of insufficient overall size, has less than 10% free space, or has a non-permitted UUID'
            or croak $ERRNO;
        next;
    }
    return 0;
}

sub is_permitted {
    my $UUID = `/sbin/blkid /dev/$symlink`;
    ($UUID) = $UUID =~ /UUID="(.+?)"/xms;
    ### $UUID
    if ( "@allowed_uuids" =~ /$UUID/ixms ) {
        return 0;
    }
    else {
        return 1;
    }
}

sub is_large_enough {
    my $size_in_gb = 512 * `cat $real_device/size` / 1000 / 1000 / 1000;
    ### $size_in_gb
    if ( $size_in_gb >= 500 ) {
        return 0;
    }
    else {
        return 1;
    }
}

sub has_free_space {
    my $space_used = `df /dev/$base_device`;
    ($space_used) = ( $space_used =~ /([[:digit:]]+)%/xms );
    if ( $space_used < 90 ) {
        return 0;
    }
    else {
        return 1;
    }
}

sub backup {

    # Ensure needed directories are made
    my $local_symlink = "/dev/$symlink";
    $backup_to = "/mnt/$symlink";
    ### $local_symlink
    ### $backup_to
    ### $source_dir
    if ( !-d $backup_to ) {
        system "mkdir -p $backup_to" and croak $ERRNO;
    }

    system "mount $local_symlink $backup_to" and croak $ERRNO;
    sleep 2;
    my $backup_to_full = $backup_to . qw{/} . `hostname`;
    chomp $backup_to_full;
    if ( !-d $backup_to_full ) {
        system "mkdir $backup_to_full" and croak $ERRNO;
    }

    $rsync_start_time = strftime '%F %T', localtime;
    ### $rsync_start_time

    # Fork so we can keep track of the PID
    if ( $pid = fork ) {
        my $childpid = wait;
        $rsync_status_return = $CHILD_ERROR >> 8;
    }
    elsif ( defined $pid ) {

        # Mind the trailing / at the end of $source_dir
        exec "$rsync \"$source_dir/\" \"$backup_to_full\" 2>&1"
            or croak $ERRNO;
    }
    else {
        croak "Fork failed: $ERRNO";
    }

    my $cur_time = strftime '%c', localtime;
    my $return_code;
    if ( $rsync_status_return != 0 ) {
        $return_code = 1;
        $rsync_output
            = "Backup from $source_dir to $backup_to_full experienced problems.\nrsync error code: $rsync_status_return;\nPlease contact SmartSystems for further assistance.\n";
        ### $rsync_output
        $email_subject
            = "UVB: [WARNING] Backup report from $source_dir at $cur_time";
        ### $email_subject
    }
    else {
        $return_code = 0;
        $rsync_output
            = "Backup from $source_dir to $backup_to_full completed successfully.\nIt is now safe to remove the drive.\n";
        ### $rsync_output
        $email_subject
            = "UVB: [SUCCESS] Backup report from $source_dir at $cur_time";
        ### $email_subject
    }

# Clean up after ourselves; ensure we don't croak otherwise we'll never get to the output
    my @other_errors;

    system "umount $backup_to" and push @other_errors, "\n$ERRNO";
    system "rmdir $backup_to"  and push @other_errors, "\n$ERRNO";
    system "rm /dev/$symlink"  and push @other_errors, "\n$ERRNO";
    if ( defined $rsync_start_time ) {
        $rsync_stop_time = strftime '%F %T', localtime;
        ### $rsync_stop_time
    }
    my $duration = time - $start;
    ### $duration
    my $log_output;
    {
        local $INPUT_RECORD_SEPARATOR = undef;
        open my $fh, '<', $rsync_log
            or carp "can't open $rsync_log $ERRNO";
        $log_output = <$fh>;
        close $fh or carp $ERRNO;
    }

    $email_output
        = "$rsync_output\nOther errors:@other_errors\nStart time: $rsync_start_time\nStop time: $rsync_stop_time\nDuration: $duration\nLog file output:$log_output";

    ### $email_output
    my @command = ( "$mail_bin", '-s', $email_subject, @emails );
    open my $mail, q{|-}, @command or croak $ERRNO;
    printf {$mail} "%s\n", $email_output;
    close $mail or croak $ERRNO;

    system "rm $rsync_log";
    return $return_code;
}

sub cleanup {
    say 'Script terminated, cleaning up...' or croak $ERRNO;
    system "umount $backup_to";
    system "rmdir $backup_to";
    system "rm /dev/$symlink";
    system "rm $rsync_log";

    # Kill rsync
    kill 'SIGTERM', $pid;
    return 0;
}

__END__

=pod Changelog

=begin comment

Changelog:

0.3:
    -Reorganised the e-mail into concrete parts. Added SUCCESS and WARNING tags along with %F %T timestamps
    -Added rsync log files to the e-mail body; the log is deleted afterwards or on SIGTERM
    -Re-organised the backup sub-procedure to be less complex and to fix the logic resulting in blank e-mails.
    -Adjusted the logic in the INIT block to prevent a misleading error message.

0.2:
    -Added 'UVB:' to the subject line in the e-mails for easier sorting
    -Changed the logic of the final 'system' commands to collect any errors in
     an array instead of croaking and show them on-screen and in the e-mail
    -Made mailx and rsync locations and parameters into variables instead of
     being hard-coded, defined during the check for existence
        -Made adjustments to the init block to follow suit
    -Added checks for ~/.mailrc and ~/.msmtprc, croaking if they're not found
    -Corrected an error in the documentation which claimed the disk needed to
     be >=128GB when in fact it must be >=500GB
    -Corrected the omission of the UUID list in the DESCRIPTION
    -Cleaned up the documentation in general
    -Added a duration timer which should show up in the e-mail
    -The call to rsync(1) now explicitly forks, and a signal trap/cleanup
     routine has been added to deal with the temporary files and ensure rsync(1)
     dies gracefully in the event of a SIGTERM

0.1:
    -Initial version, based on v0.2 of usb2nas.pl
    -Various cleanups relative to usb2nas.pl
    -Added basic checks for installed utility programs, assuming a
     Debian/Ubuntu operating environment

=end comment

=cut

# Documentation
=pod

=head1 NAME

ssbak2bak -- Backs up from a local machine to USB based on a udev rule

=head1 USAGE

    perl ssbak2bak.pl   [OPTION...]
    -h, --help          Display this help text
        --debug         Enables debug mode
        --man           Displays the full embedded manual
        --version       Displays the version and then exits
    -e, --emails        E-mail addresses to send reports to
    -s, --source        Directory to back up
    -u, --uuids         List of UUIDs of partitions to back up to

=head1 DESCRIPTION

Intended to be used in conjunction with a udev rule, this script looks at all
external drives on the system; should any be larger than 500 gigabytes, have at
least 10% free space, and be on the list of approved drives (determined via
UUID) it will be backed up to, and then notify you via e-mail. Requires root
access and pre-configuration of the mail elements, detailed under
L<CONFIGURATION|CONFIGURATION>. Assumes one partition is present on the target
disk; if more than one is present, be aware that the first partition (e.g.
/dev/sda1) will be used. Also assumes that the disk structure follows the
pattern of either 'sdX' or 'xvdX', as it is intended originally for running
under a Xen hypervisor.

=head1 REQUIRED ARGUMENTS

Requires an e-mail address, a source directory, and a list of allowed UUIDs, as
detailed in L<USAGE|USAGE>.

=head1 OPTIONS

See L<USAGE|USAGE>. Further details on formatting are found under
L<CONFIGURATION|CONFIGURATION>.

=head1 DIAGNOSTICS

Ensure that your ~/.msmtprc, your ~/.mailrc, and your udev rules both exist and
are configured correctly. Sample configurations for the udev rule, and
~/.msmtprc are provided below. Don't forget to chmod ~/.msmtprc to 600 (r-w
only for the user)

=head1 EXIT STATUS

0 for success, 1 for either quitting prematurely due to another instance
running or for other issues which will be present in the output.

=head1 CONFIGURATION

Sample /etc/udev/rules.d/backup.rules:

    # Backup rules
    SUBSYSTEM=="block", ACTION=="add", KERNEL=="xvd*", SYMLINK+="safety%k"
    SUBSYSTEM=="block", ACTION=="add", KERNEL=="xvd[e-z]1", RUN+="bash -c 'export HOME=/home/foo && /home/foo/.local/bin/ssbak2bak/ssbak2bak.pl | at now'"

What this does is check for any drive that is successfully added, then creates
a symlink to it and every partition on it for safety's sake. It then runs the
script explicitly, piping the whole thing into L<at(1)|at(1)> to avoid blocking
udev. Note that this rule will run for every partition on the drive; for that
reason, this script will only allow itself to be started once, using
Fcntl ':flock'.

It also requires e-mail to be configured, specifically requiring
L<mail(1)|mail(1)> and L<msmtp(1)|msmtp(1)>.

B<You'll need to add 'set sendmail="/usr/bin/msmtp"' to your ~/.mailrc or /etc/mailrc as well.>

For reference, here's a sample .msmtprc:

    account Test
    host 10.100.100.115
    port 1025
    protocol smtp
    from foo@mycompany.com
    auth login
    user foo.bar
    password mySecurePass123
    logfile ~/.msmtp.test.log
    account default: Test

For convenience, all of the required parameters can be put into a simple INI
config file in '$HOME/.local/share/SS/ssbak2bak', e.g.:

    emails=foo@mycompany.com, bar@mycompany.com
    source=/mnt/bds/2688a528d293-48b9-7634-7b9d-96c72c74
    allowed_uuids=F82163C4F363C4E9, 2AAA4AD36D020A26

=head1 DEPENDENCIES

Perl:

    -Perl of a recent vintage (developed on 5.18.2)
    -Config::Simple (cpan Config::Simple or dpkg libconfig-simple-perl)
    -Smart::Comments (cpanm Smart::Comments or dpkg libsmart-comments-perl)
        -The call for this can be commented out at the top of the script if
         this functionality is unneeded

External:

    -df (coreutils)
    -readlink (coreutils)
    -rsync (rsync)
    -mail (heirloom-mailx)
    -msmtp (msmtp)
    -udev (udev)
    -udev rules

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

Report any bugs found to either the author or to the SmartSystems support
account, <support@smartsystemsaz.com>

=head1 AUTHOR

Cory Sadowski <cory@smartsystemsaz.com>

=head1 LICENSE AND COPYRIGHT

(c) 2015 SmartSystems, Inc.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.

=cut
