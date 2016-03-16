#!/usr/bin/env perl

# This script is intended to be run from dom0, which should be running
# usbmap-to-vm.sh. It is intended to be run as a job in cron.daily in order to
# re-use the backup drive currently plugged in.

use strict;
use warnings;

# Modules

use Carp;                          # Core
use English qw(-no_match_vars);    # Core
use POSIX qw(strftime);            # Built-in

our $VERSION = 0.1;

my $cur_time   = strftime '%Y%m%d', localtime;
my $check_file = $ENV{'HOME'} . '/.local/share/SS/ssbak2bak/autoruntime.txt';
my $usbmap     = $ENV{'HOME'} . '/.local/share/SS/ssbak2bak/usbmap-to-vm.sh';

if ( $EFFECTIVE_USER_ID != 0 ) {
    die "This script can only run as root\n";
}

if ( !-e $check_file ) {
    open my $fh, '>', $check_file
        or croak "Couldn't open file $check_file: $ERRNO";
    print {$fh} $cur_time;
    close $fh               or croak "$ERRNO";
    system "$usbmap detach" or croak "$ERRNO";
    exec "$usbmap attach"   or croak "$ERRNO";
}
else {
    open my $fh, '<', $check_file
        or croak "Couldn't open file $check_file: $ERRNO";
    my $recorded_time = <$fh>;
    close $fh or croak "$ERRNO";
    if ( $recorded_time !~ /^[[:digit:]]{8}$/xms ) {
        open my $fh, '>', $check_file
            or croak "Couldn't open file $check_file: $ERRNO";
        print {$fh} $cur_time;
        close $fh or croak "$ERRNO";
        die
            "File $check_file corrupted. Overwriting with correct data and assuming no run\n";
    }
    if ( $recorded_time < $cur_time ) {
        open my $fh, '>', $check_file
            or croak "Couldn't open file $check_file: $ERRNO";
        print {$fh} $cur_time;
        close $fh               or croak "$ERRNO";
        system "$usbmap detach" or croak "$ERRNO";
        exec "$usbmap attach"   or croak "$ERRNO";
    }
    else {
        die "Automatic backup was already ran today\n";
    }
}
