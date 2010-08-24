###__PERLBIN__###

use warnings;
use strict;
use Getopt::Long;
use GNUpod::FooBar;

my %opts = (mount => $ENV{IPOD_MOUNTPOINT});

GetOptions(\%opts, "version", "help|h", "mount|m=s");
GNUpod::FooBar::GetConfig(\%opts, {mount => 's'}, "gnupod_sync");

usage() if $opts{help};
version() if $opts{version};

my $connection = GNUpod::FooBar::connect(\%opts);
usage($connection->{status}."\n") if $connection->{status};

sub usage {
    my ($msg) = @_;
    warn "$msg\n" if $msg;
    die "gnupod_sync.pl - use to sync iTunesDB and OTG data with GNUpod.\n"
}

sub version {
    die "gnupod_sync.pl (gnupod) version ###__VERSION__###\n";
}
