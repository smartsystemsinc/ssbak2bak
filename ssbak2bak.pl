#!/usr/bin/env perl

# Force me to write this properly

use strict;
use warnings;

# Modules

use Carp;              # Built-in
use Config::Simple;    # dpkg libconfig-simple-perl || cpan Config::Simple
use English qw(-no_match_vars);                 # Built-in
use Getopt::Long qw(:config no_ignore_case);    # Built-in
use Pod::Usage;                                 # Built-in
use POSIX qw(strftime);                         # Built-in
use Fcntl ':flock';                             # Built-in

INIT {
    if ( !flock main::DATA, LOCK_EX | LOCK_NB ) {
        my $email;
        my $cur_time = strftime '%c', localtime;

        # Try to read in parameters from the config file
        my $base_dir = $ENV{'HOME'} . '/.local/share/SS/ssbak2bak';
        my $config   = "$base_dir/config.ini";
        if ( -f "$config" ) {
            my $cfg = Config::Simple->new();
            $cfg->read("$config") or croak $ERRNO;
            $email = $cfg->param('email');

            # Override parameters if entered on the command line
            GetOptions( 'email|e:s' => \$email, )
                or carp "No e-mail defined -- user cannot be notified\n";
            print "$PROGRAM_NAME is already running\n" or croak $ERRNO;
            if ( !$email ) {
                system
                    "echo \"$PROGRAM_NAME is already running\" | mail -s \"Error report from $PROGRAM_NAME at $cur_time\" $email"
                    and croak $ERRNO;
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

our $VERSION = '0.1';

# Set variables
my @allowed_uuids;
my $base_device;
my $base_dir = $ENV{'HOME'} . '/.local/share/SS/ssbak2bak';
my $config   = "$base_dir/config.ini";
my $email;
my $real_device;
my $real_device_base;
my $source_dir;
my $symlink;
my @symlinks;

# Ensure directory exists
if ( !-d $base_dir ) { system "mkdir -p $base_dir" and croak $ERRNO; }

# Try to read in parameters from the config file
if ( -f "$config" ) {
    my $cfg = Config::Simple->new();
    $cfg->read("$config") or croak $ERRNO;
    $email         = $cfg->param('email');
    $source_dir    = $cfg->param('source');
    @allowed_uuids = $cfg->param('allowed_uuids');
}

# Override parameters if entered on the command line
GetOptions(
    'help|h'       => \my $help,
    'debug'        => \my $debug,            # dummy variable
    'man'          => \my $man,
    'version|v'    => \my $version,
    'email|e:s'    => \$email,
    'source|s:s'   => \$source_dir,
    'uuids|u:s{,}' => \my @allowed_uuids2,

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
if ( $email !~ m/^\w+[@][\d[:alpha:]\-]{1,}[.]{1,}[\d[:alpha:]-]{2,6}$/xms ) {
    croak "Invalid e-mail address syntax\n";
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
    print "Finished\n" or croak $ERRNO;
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

    if ( `which rsync` eq q{} ) {
        print "rsync not found. Attempting to install.\n" or croak $ERRNO;
        system 'sudo apt-get install rsync --yes' and croak $ERRNO;
    }

    if ( `which mail` eq q{} ) {
        print "heirloom-mailx not found. Attempting to install.\n"
            or croak $ERRNO;
        system 'sudo apt-get install heirloom-mailx --yes'
            and croak $ERRNO;
    }

    if ( `which msmtp` eq q{} ) {
        print "msmtp not found. Attempting to install.\n" or croak $ERRNO;
        system 'sudo apt-get install msmtp --yes' and croak $ERRNO;
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
        print
            "Disk is of insufficient overall size, has less than 10% free space, or has a non-permitted UUID\n"
            or croak $ERRNO;
        next;
    }
    return 0;
}

sub is_permitted {
    my $UUID = `blkid /dev/$symlink`;
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

    my $local_symlink = "/dev/$symlink";
    my $backup_to     = "/mnt/$symlink";
    ### $local_symlink
    ### $backup_to
    ### $source_dir
    if ( !-d $backup_to ) {
        system "mkdir -p $backup_to" and croak $ERRNO;
    }
    system "mount $local_symlink $backup_to";
    sleep 2;
    my $backup_to_full = $backup_to . qw{/} . `hostname`;
    chomp $backup_to_full;
    if ( !-d $backup_to_full ) {
        system "mkdir $backup_to_full" and croak $ERRNO;
    }
    system

        # Mind the trailing / at the end of $source_dir
        "rsync --archive --hard-links --acls --xattrs --verbose \"$source_dir/\" \"$backup_to_full\" 2>&1";
    my $rsync_status_return = $CHILD_ERROR >> 8;
    my $rsync_status_error  = $ERRNO;
    my $rsync_output;

    if ( $rsync_status_return != 0 && $rsync_status_error != 0 ) {
        $rsync_output
            = "Rsync reported issues.\nrsync error code: $rsync_status_return;\nrsync error message: $rsync_status_error\n";
        ### $rsync_output
    }
    else {
        $rsync_output
            = "Backup from $source_dir to $backup_to_full completed successfully.\n";
        ### $rsync_output
    }

    system "umount $backup_to" and croak $ERRNO;
    system "rmdir $backup_to"  and croak $ERRNO;
    system "rm /dev/$symlink"  and croak $ERRNO;
    my $cur_time = strftime '%c', localtime;
    system
        "echo \"Backup complete. Rsync output: $rsync_output\" | mail -s \"Backup report from $source_dir at $cur_time\" $email"
        and croak $ERRNO;
    return 0;
}

__END__

=pod Changelog

=begin comment

Changelog:

0.1:
    -Initial version, based on v0.2 of usb2nas.pl
    -Various cleanups relative to usb2nas.pl
    -Added basic checks for installed utility programs

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
    -e, --email         E-mail address to send reports to
    -s, --source        Directory to back up
    -u, --uuids         List of UUIDs of partitions to back up to

=head1 DESCRIPTION

Intended to be used in conjunction with a udev rule, this script looks at all
external drives on the system and should it be larger than 128 gigabytes and
have at least 10% free space it will be backed up to, and then notify you via
e-mail. Requires root access and pre-configuration of the mail elements,
detailed under L<CONFIGURATION|CONFIGURATION>. Assumes one partition is present
on the target disk; if more than one is present, be aware that the first
partition (e.g. /dev/sda1) will be used. Also assumes that the disk structure
follows the pattern of either 'sdX' or 'xvdX', as it is intended originally for
running under a Xen hypervisor.

=head1 REQUIRED ARGUMENTS

Requires an e-mail address, a source directory, and a list of allowed UUIDs, as
detailed in L<USAGE|USAGE>.

=head1 OPTIONS

See L<USAGE|USAGE>. There's really nothing to configure here at the moment
aside from local debug output.

=head1 DIAGNOSTICS

Ensure that your .msmtprc, your ~/.mailrc, and your udev rule are configured
correctly; ensure also that L<rsync(1)|rsync(1)> is installed correctly.
Sample configurations for the udev rule and msmtp are provided below. Don't
forget to chmod ~/.msmtprc to 600 (r-w only for the user)

=head1 EXIT STATUS

0 for success, 1 for either quitting prematurely due to another instance
running or for other issues which will be present in the output.

=head1 CONFIGURATION

Sample /etc/udev/rules.d/backup.rules:

    # Backup rules
    SUBSYSTEM=="block", ACTION=="add", KERNEL=="xvd*", SYMLINK+="safety%k"
    SUBSYSTEM=="block", ACTION=="add", KERNEL=="xvd[ef]1", RUN+="/home/admin/.local/share/SS/ssbak2bak/ssbak2bak.pl | at now"

What this does is check for any drive that is successfully added, then creates
a symlink to it and every partition on it for safety's sake. It then runs the
script explicitly, piping the whole thing into L<at(1)|at(1)> to avoid blocking
udev. Note that this rule will run for every partition on the drive; for that
reason, this script will only allow itself to be started once, using
Fcntl ':flock'.

It also requires e-mail to be configured, specifically requiring
L<mail(1)|mail(1)> and L<msmtp(1)|msmtp(1)>. You'll need to add 'set
sendmail="/usr/bin/msmtp"' to your ~/.mailrc or /etc/mailrc as well.
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

    email=foo@mycompany.com
    source=/mnt/bds/2688a528d293-48b9-7634-7b9d-96c72c74
    allowed_uuids=F82163C4F363C4E9, 2AAA4AD36D020A26

=head1 DEPENDENCIES

Perl:

    -Perl of a recent vintage (developed on 5.18.2)
    -Config::Simple; (cpan Config::Simple or dpkg libconfig-simple-perl)
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
    -udev rule

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

Report any bugs found to either the author or to the SmartSystems support
account, <support@smartsystemsaz.com>

=head1 AUTHOR

Cory Sadowski <cory@smartsystemsaz.com>

=head1 LICENSE AND COPYRIGHT

To be determined.

=cut
