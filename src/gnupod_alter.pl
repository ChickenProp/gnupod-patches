#!/usr/bin/perl

use warnings qw(FATAL all);
use strict;
use Getopt::Long;
use GNUpod::FooBar;
# GNUpod::XMLhelper is weird and undocumented. Fiddle with the XML directly.
use XML::LibXML;

use vars qw( %opts );

$opts{mount} = $ENV{IPOD_MOUNTPOINT};
$opts{delim} = "\t";
GetOptions(\%opts, "mount|m=s", "file|f=s", "delim|d=s");

# Reads config from rcfiles. Doesn't overwrite options that already exist.
# The third arg allows config specific to this program, eg with
# gnupod_alter.delim = |
# (I don't think there's any way of including leading whitespace, which is a
# problem for delim.)
GNUpod::FooBar::GetConfig(\%opts, { mount => 's', delim => 's' },
			  "gnupod_alter");

my $gtdb = $opts{file};
if (!$gtdb) {
	my $con = GNUpod::FooBar::connect(\%opts);
	die $con->{status}, "\n" if $con->{status};
	$gtdb = $con->{xml};
}

my $filter = shift;
usage() if !$filter;

my @attrs = @ARGV;
usage() if !@attrs;

my $p = XML::LibXML->new();
my $xml = $p->parse_file($gtdb);
my $doc = $xml->getDocumentElement();
my @songs = $doc->getElementsByTagName("file")->get_nodelist();

while (my $line = <STDIN>) {
	chomp $line;
	my @line = split($opts{delim}, $line);
	foreach my $song (@songs) {
		process_song($song, @line);
	}
}

# We queue the copy operations and do them all at the end, so that if we need
# to die, nothing's changed.
copy_files();

open(my $out, '>', $gtdb);
$xml->toFH($out);

sub process_song {
	my ($song, $match, @update) = @_;
	if (matchattr($song, $filter, $match)) {
		update_song($song, @update);
	}
}

sub update_song {
	my ($song, @update) = @_;
	foreach my $attr (@attrs) {
		setattr($song, $attr, shift @update);
	}
}

sub getattr {
	my ($song, $attr) = @_;

	if ($attr =~ /^:/) {
		$song->getAttribute(substr($attr,1));
	}
	else {
		no strict 'refs';
		my $subname = "getattr_$attr";
		$subname =~ tr/-/_/;
		
		if (defined &$subname) {
			&$subname($song);
		}
		else {
			$song->getAttribute($attr);
		}
	}
}

sub setattr {
	my ($song, $attr, $new) = @_;

	if ($attr =~ /^:/) {
		$song->setAttribute(substr($attr,1), $new);
	}
	else {
		no strict 'refs';
		my $subname = "setattr_$attr";
		$subname =~ tr/-/_/;
		
		if (defined &$subname) {
			&$subname($song, $new);
		}
		else {
			$song->setAttribute($attr, $new);
		}
	}
}

sub matchattr {
	my ($song, $attr, $match) = @_;
	return ($match eq getattr($song, $attr));
}

{
	my @moves = ();
	sub schedule_copy {
		#print "pushing @_\n";
		push @moves, [@_];
	}

	sub copy_files {
		for my $m (@moves) {
			print "copying $m->[0] to $m->[1]\n";
		}
	}
}

sub getattr_rating {
	$_[0]->getAttribute("rating") || 0;
}

sub getattr_unixpath {
	my $p = $_[0]->getAttribute("path");
	$p =~ tr|:|/|;
	return $opts{mount}.$p;
}

sub setattr_file {
	my ($song, $new) = @_;
	my $old = getattr($song, "unixpath");
	schedule_copy($new, $old);
}


sub usage {
    print <<"EOT";
Usage: $0 filter attr1 ...
Currently the only thorough documentation is the source code.
Illustrative examples:

% echo "739\tHello, Goodbye\tThe Beatles" | $0 id title artist
Changes song with id 739 to now have title "Hello, Goodbye" and artist "The
Beatles".

% echo "80\t100" | $0 rating rating
Changes all songs with 4-star ratings to have 5-star ratings.

% echo "Queen\tmusic/queen" | $0 artist file-from-dir
For every song by Queen, update the file on the ipod to an appropriate one from
the directory music/queen. "Appropriate" means with the same title, artist and
track number.
EOT

    exit 1;
}
