###__PERLBIN__###

use warnings;
use strict;
use Getopt::Long;
use GNUpod::FooBar;
# GNUpod::XMLhelper is weird and undocumented. Fiddle with the XML directly.
use XML::LibXML;

use vars qw( %opts );

$opts{mount} = $ENV{IPOD_MOUNTPOINT};
$opts{delim} = "\t";
GetOptions(\%opts, "mount|m=s", "file|f=s", "delim|d=s", "playlist=s");

# Reads config from rcfiles. Doesn't overwrite options that already exist.
# The third arg allows config specific to this program, eg with
# gnupod_dumpsongs.delim = |
# (I don't think there's any way of including leading whitespace, which is a
# problem for delim.)
GNUpod::FooBar::GetConfig(\%opts, { mount => 's', delim => 's' },
			  "gnupod_dumpsongs");

my $gtdb = $opts{file};
if (!$gtdb) {
    my $con = GNUpod::FooBar::connect(\%opts);
    die $con->{status}, "\n" if $con->{status};
    $gtdb = $con->{xml};
}

my @atrs = @ARGV;
if (! @atrs) {
    @atrs = qw(id rating playcount title);
}

my $p = XML::LibXML->new();

my $doc = $p->parse_file($gtdb)->getDocumentElement();
my @songs = $doc->getElementsByTagName("file")->get_nodelist();

if (not defined $opts{playlist}) {
    foreach my $song (@songs) {
	print_song($song);
    }
}
else {
    my @pls = $doc->getElementsByTagName("playlist")->get_nodelist();
    my ($pl) = grep { $_->getAttribute("name") eq $opts{playlist} } @pls;
    my @adds = $pl->getElementsByTagName("add")->get_nodelist();
    my @ids = map { $_->getAttribute("id") } @adds;
    
    for my $id (@ids) {
	print_song(song_by_id($id));
    }
}

sub song_by_id {
    my ($id) = @_;
    my @f = grep { $_->getAttribute("id") eq $id } @songs;
    return $f[0];
}

sub print_song {
    my ($song) = @_;
    my $first = 1;
    foreach my $atr (@atrs) {
	if ($first) {
	    $first = 0;
	} else {
	    print $opts{delim};
	}
	
	my $s = "";
	if ($atr =~ /^:/) {
	    $s = $song->getAttribute(substr($atr,1));
	} elsif ($atr eq "rating") {
	    $s = $song->getAttribute("rating") || 0;
	} elsif ($atr eq "stars") {
	    $s = ($song->getAttribute("rating") || 0)/20;
	} elsif ($atr eq "unixpath") {
	    my $p = $song->getAttribute("path");
	    $p =~ tr|:|/|;
	    $s = $opts{mount}.$p;
	} elsif ($atr eq "lastplay") {
	    my $t = $song->getAttribute("lastplay");
	    if (defined $t) {
		$t -= 2082848400; # convert mac to unix time.
		my ($sec,$min,$hour,$mday,$mon,$year) = localtime($t);
		$year += 1900;
		$s = sprintf("%04d-%02d-%02d %02d:%02d:%02d",
			     $year, $mon+1, $mday, $hour, $min, $sec);
	    } else {
		$s = '-'x19;
	    }
	} else {
	    $s = $song->getAttribute($atr);
	}
	print $s if defined $s;
    }
    print "\n";
}    
