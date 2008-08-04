###__PERLBIN__###
#  Copyright (C) 2002-2007 Adrian Ulrich <pab at blinkenlights.ch>
#  Part of the gnupod-tools collection
#
#  URL: http://www.gnu.org/software/gnupod/
#
#    GNUpod is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 3 of the License, or
#    (at your option) any later version.
#
#    GNUpod is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.#
#
# iTunes and iPod are trademarks of Apple
#
# This product is not supported/written/published by Apple!

use strict;
use GNUpod::XMLhelper;
use GNUpod::FooBar;
use GNUpod::FileMagic;
use GNUpod::ArtworkDB;
use Getopt::Long;
use File::Copy;
use File::Glob ':glob';
use Date::Parse;

use constant MEDIATYPE_PODCAST_AUDIO => 4;
use constant MEDIATYPE_PODCAST_VIDEO => 6;

use constant MACTIME => GNUpod::FooBar::MACTIME;
use vars qw(%opts %dupdb_normal %dupdb_lazy %dupdb_podcast $int_count %podcast_infos %podcast_channel_infos %per_file_info);

print "gnupod_addsong.pl Version ###__VERSION__### (C) Adrian Ulrich\n";

$int_count = 3; #The user has to send INT (Ctrl+C) x times until we stop

$opts{mount} = $ENV{IPOD_MOUNTPOINT};
#Don't add xml and itunes opts.. we *NEED* the mount opt to be set..
GetOptions(\%opts, "version", "help|h", "mount|m=s", "decode|x=s", "restore|r", "duplicate|d", "disable-v2", "disable-v1",
                   "set-title|t=s", "set-artist|a=s", "set-album|l=s", "set-genre|g=s", "set-rating=i", "set-playcount=i",
                   "set-bookmarkable|b", "set-shuffleskip", "artwork=s",
                   "set-songnum", "playlist|p=s@", "reencode|e=i",
                   "min-vol-adj=i", "max-vol-adj=i", "playlist-is-podcast", "podcast-files-limit=i", "podcast-cache-dir=s",
                   "podcast-artwork", "set-compilation");

GNUpod::FooBar::GetConfig(\%opts, {'decode'=>'s', mount=>'s', duplicate=>'b', model=>'s',
                                   'disable-v1'=>'b', 'disable-v2'=>'b', 'set-songnum'=>'b',
                                   'min-vol-adj'=>'i', 'max-vol-adj'=>'i', 'automktunes'=>'b', 
                                   'podcast-files-limit'=>'i', 'podcast-cache-dir'=>'s', 'podcast-artwork'=>'b' },
                                   "gnupod_addsong");



usage("\n--decode needs 'pcm' 'mp3' 'aac' 'video' or 'aacbm' -> '--decode=mp3'\n") if $opts{decode} && $opts{decode} !~ /^(mp3|video|aac|aacbm|pcm|crashme)$/;
usage()   if $opts{help};
version() if $opts{version};

$SIG{'INT'} = \&handle_int;
my @XFILES  = ();

if($opts{restore}) {
	print "If you use --restore, you'll *lose* your playlists and cover artwork!\n";
	print " Hit ENTER to continue or CTRL+C to abort\n\n";
	<STDIN>;
	@XFILES = bsd_glob("$opts{mount}/i*/Music/[Ff]*/*", GLOB_NOSORT)
}
elsif($ARGV[0] eq "-" && @ARGV == 1) {
	print STDERR "Reading from STDIN, hit CTRL+D (EOF) when finished\n";
	while(<STDIN>) {
		chomp;
		push(@XFILES, $_); #This eats memory, but it isn't so bad...
	}
}
else {
	@XFILES = @ARGV;
}


my $connection = GNUpod::FooBar::connect(\%opts);
usage($connection->{status}."\n") if $connection->{status} || !@XFILES;

my $AWDB  = GNUpod::ArtworkDB->new(Connection=>$connection, DropUnseen=>($opts{'podcast-artwork'}?0:1));
my $awdb_image_prepared = 0 ;

my $exit_code = startup($connection,@XFILES);
exit($exit_code);





####################################################
# Worker
sub startup {
	my($con,@argv_files) = @_;
	
	#Don't sync if restore is true
	$opts{_no_sync} = $opts{restore};
	my $fatal_error = 0;
	
	if($opts{restore}) {
		# Some options don't mix well with --restore
		delete($opts{artwork});
		delete($opts{playlist});
		delete($opts{decode});
		$opts{duplicate} = 1;
	}
	else {
		if($opts{artwork}) {
			if ( ! add_image_to_awdb($opts{artwork})) {
				warn "$0: Could not load $opts{artwork}, skipping artwork\n";
				delete($opts{artwork});
			}
		}
		GNUpod::XMLhelper::doxml($con->{xml}) or usage("Failed to parse $con->{xml}, did you run gnupod_INIT.pl?\n");
	}
	
	if($opts{playlist}) { #Create this playlist
		foreach my $xcpl (@{$opts{playlist}}) {
			print "> Adding songs to Playlist '$xcpl'\n";
			GNUpod::XMLhelper::addpl($xcpl, {podcast=>$opts{'playlist-is-podcast'}}); #Fixme: this may printout a warning..
		}
	}
	
	
	# Check volume adjustment options for sanity
	my $min_vol_adj = int($opts{'min-vol-adj'});
	my $max_vol_adj = int($opts{'max-vol-adj'});
	
	usage("Invalid settings: --min-vol-adj=$min_vol_adj > --max-vol-adj=$max_vol_adj\n") if ($min_vol_adj > $max_vol_adj);
	usage("Invalid settings: --min-vol-adj=$min_vol_adj < -100\n")                       if ($min_vol_adj < -100);
	usage("Invalid settings: --max-vol-adj=$max_vol_adj > 100\n")                        if ($max_vol_adj > 100);
	
	
	#We parsed the XML-Document
	#resolve_podcasts fetches new podcasts from http:// stuff and adds them to real_files
	my @real_files = resolve_podcasts(@argv_files);
	my $addcount   = 0;
	
	#We are ready to copy each file..
	foreach my $file (@real_files) {
		#Skip all songs if user sent INT
		next if !$int_count;
		#Skip all dirs
		next if -d $file;
		
		#Get the filetype
		my ($fh,$media_h,$converter) =  GNUpod::FileMagic::wtf_is($file, {noIDv1=>$opts{'disable-v1'}, 
		                                                                  noIDv2=>$opts{'disable-v2'},
		                                                                  decode=>$opts{'decode'}},$con);
		
		unless($fh) {
			warn "* [****] Skipping '$file', unknown file type\n";
			next;
		}
		
		my $wtf_ftyp = $media_h->{ftyp};      #'codec' .. maybe ALAC
		my $wtf_frmt = $media_h->{format};    #container ..maybe M4A
		my $wtf_ext  = $media_h->{extension}; #Possible extensions (regexp!)
		
		#Force tags for current file
		#This is only used for RSS ATM.
		my $c_per_file_info = $per_file_info{$file};
		foreach(keys(%$c_per_file_info)) {
			next unless lc($_) eq $_; #lc keys are there to overwrite $fh keys
			$fh->{$_} = $c_per_file_info->{$_};
		}
		$c_per_file_info->{ISPODCAST} ||= $opts{'playlist-is-podcast'};  # Enforce podcast settings if we are going to create a pc-playlist
		
		
		#wtf_is found a filetype, override data if needed
		$fh->{artist}       = $opts{'set-artist'}      if $opts{'set-artist'};
		$fh->{album}        = $opts{'set-album'}       if $opts{'set-album'};
		$fh->{genre}        = $opts{'set-genre'}       if $opts{'set-genre'};
		$fh->{rating}       = $opts{'set-rating'}      if $opts{'set-rating'};
		$fh->{compilation}  = 1                        if defined($opts{'set-compilation'});
		$fh->{bookmarkable} = 1                        if defined($opts{'set-bookmarkable'});
		$fh->{shuffleskip}  = 1                        if defined($opts{'set-shuffleskip'});
		$fh->{playcount}    = $opts{'set-playcount'}   if $opts{'set-playcount'};
		$fh->{title}        = $opts{'set-title'}       if $opts{'set-title'};
		$fh->{songnum}      = 1+$addcount              if $opts{'set-songnum'};
		if($awdb_image_prepared) {
			$fh->{has_artwork} = 1;
			$fh->{artworkcnt}  = 1;
			$fh->{dbid_1}      = $AWDB->InjectImage;
		}
		
		#Set the addtime to unixtime(now)+MACTIME (the iPod uses mactime)
		#This breaks perl < 5.8 if we don't use int(time()) !
		$fh->{addtime} = int(time())+MACTIME;
		
		#Ugly workaround to avoid a warning while running mktunes.pl:
		#All (?) int-values returned by wtf_is won't go above 0xffffffff
		#Thats fine because almost everything inside an mhit can handle this.
		#But bpm and srate are limited to 0xffff
		# -> We fix this silently to avoid ugly warnings while running mktunes.pl
		$fh->{bpm}   = 0xFFFF if $fh->{bpm}   > 0xFFFF;
		$fh->{srate} = 0xFFFF if $fh->{srate} > 0xFFFF;


		#Check for duplicates
		if(!$opts{duplicate} && (my $dup = checkdup($fh,$converter))) {
			print "! [!!!!] '$file' is a duplicate of song $dup, skipping file\n";
			create_playlist_now($opts{playlist}, $dup); #We also add duplicates to a playlist..
			next;
		}
		
		# If this was a podcast, we need to fixup the mediatype
		if($c_per_file_info->{ISPODCAST}) {
			$fh->{shuffleskip}   = 1;
			$fh->{bookmarkable}  = 1;
			$fh->{podcast}       = 1;
			$fh->{podcastguid} ||= sprintf("GNUpodG%X",int(rand(0xFFFFF)));
			$fh->{podcastrss}  ||= sprintf("GNUpodR%X",int(rand(0xFFFFF)));
			
			if($fh->{mediatype} == GNUpod::FileMagic::MEDIATYPE_AUDIO) {
				$fh->{mediatype} = MEDIATYPE_PODCAST_AUDIO;
			}
			elsif($fh->{mediatype} == GNUpod::FileMagic::MEDIATYPE_VIDEO) {
				$fh->{mediatype} = MEDIATYPE_PODCAST_VIDEO;
				$wtf_frmt = "m4v"; # Enforce M4V as extension
				$wtf_ext  = '';    # no multiple choices, sorry
			}
		}
		
		if($converter) {
			print "> Converting '$file' from $wtf_ftyp into $opts{decode}, please wait...\n";
			my $path_of_converted_file = GNUpod::FileMagic::kick_convert($converter,$opts{reencode},$file, uc($opts{decode}), $con);
			unless($path_of_converted_file) {
				print "! [!!!!] Could not convert $file into $opts{decode}\n";
				next;
			}
			#Ok, we got a converted file, fillout the gaps
			my($conv_fh, $conv_media_h) = GNUpod::FileMagic::wtf_is($path_of_converted_file, undef, $con);
			
			unless($conv_fh) {
				warn "* [****] Internal problem: $converter did not produce valid data.\n";
				warn "* [****] Something is wrong with $path_of_converted_file (file not deleted, debug it! :-) )\n";
				next; 	
			}
			
			#We didn't know things like 'filesize' before...
			$fh->{time}     = $conv_fh->{time};
			$fh->{bitrate}  = $conv_fh->{bitrate};
			$fh->{srate}    = $conv_fh->{srate};        
			$fh->{filesize} = $conv_fh->{filesize};   
			$wtf_frmt       = $conv_media_h->{format};    #Set the new format (-> container)
			$wtf_ext        = $conv_media_h->{extension}; #Set the new possible extension, but keep ftype (=codec)
			$file           = $path_of_converted_file;    #Point $file to new file
			$per_file_info{$file}->{UNLINK} = 1;          #Request unlink of this file after adding
		}
		elsif(defined($opts{reencode})) {
			print "> ReEncoding '$file' with quality ".int($opts{reencode}).", please wait...\n";
			my $path_of_converted_file = GNUpod::FileMagic::kick_reencode($opts{reencode},$file,$wtf_frmt,$con);
			
			if($path_of_converted_file) {
				#Ok, we could convert.. check if it made sense:
				if( (-s $path_of_converted_file) < (-s $file) ) {
					#Ok, output is smaller, we are going to use thisone
					$file = $path_of_converted_file;      # Replace the file path
					$per_file_info{$file}->{UNLINK} = 1;  # Request unlinking file (as we are going to use the copy)
				}
				else {
					#Nope.. input was smaller, converting was silly..
					print "* [****] Reencoded output bigger than input! Adding source file\n";
					unlink($path_of_converted_file) or warn "Could not unlink $path_of_converted_file, $!\n";
					#Ok, do nothing! 
				}
			}
			else {
				print "* [****] ReEncoding of file failed! Adding given file\n";
			}
		}
		
		# Clamp volume, if any
		my $vol = $fh->{volume} || 0;
		$vol = $min_vol_adj if ($vol < $min_vol_adj);
		$vol = $max_vol_adj if ($vol > $max_vol_adj);
		$fh->{volume} = $vol;
		
		#Get a path
		($fh->{path}, my $target) = GNUpod::XMLhelper::getpath($connection, $file,  {format=>$wtf_frmt, extension=>$wtf_ext, keepfile=>$opts{restore}});
		
		if(!defined($target)) {
			warn "*** FATAL *** Skipping '$file' , no target found!\n";
			$fatal_error++;
		}
		elsif($opts{restore} || File::Copy::copy($file, $target)) {
			
			# Note to myself: Using utf8() works around some obscure
			# glibc/perl/linux problem
			printf("+ [%-4s][%3d] %-32s | %-32s | %-24s\n",
			uc($wtf_ftyp),1+$addcount,
			Unicode::String::utf8($fh->{title})->utf8,
			Unicode::String::utf8($fh->{album})->utf8,
			Unicode::String::utf8($fh->{artist})->utf8);
			
			my $id = GNUpod::XMLhelper::mkfile({file=>$fh},{addid=>1}); #Try to add an id
			create_playlist_now($opts{playlist}, $id);
			$addcount++; #Inc. addcount
		}
		else { #We failed..
			warn "*** FATAL *** Could not copy '$file' to '$target': $!\n";
			unlink($target); #Wipe broken file
			$fatal_error++;
		}
		#Is it a tempfile? Remove it.
		#This is the case for 'converter' files and 'rss'
		unlink($file) if $per_file_info{$file}->{UNLINK} == 1;
	}

 
 
	if($opts{playlist} || $addcount) { #We have to modify the xmldoc
		print "> Writing new XML File, added $addcount file(s)\n";
		GNUpod::XMLhelper::writexml($con, {automktunes=>$opts{automktunes}});
	}
	$AWDB->WriteArtworkDb;
	print "\n Done\n";
	return $fatal_error;
}

#############################################################
# Preapare and add image to artwork database
sub add_image_to_awdb {
	my ($filename) = @_;
	if( $awdb_image_prepared ) {
		warn "! [****] Skipping $filename because there is already one prepared.\n";
		return 0;
	}
	my $count = $AWDB->PrepareImage(File=>$filename, Model=>$opts{model});
	if( $count ) {; 
		$AWDB->LoadArtworkDb or die "Failed to load artwork database\n";
		$awdb_image_prepared = 1;
	}
	return $count;
}
#############################################################
# Add item to playlist
sub create_playlist_now {
	my($plref, $id) = @_;
	
	
	if($plref && $id >= 0) {
		foreach my $plname (@$plref) {
			#Broken-by-design: We don't have a ID-Pool for playlists..
			#-> Create a fake_entry
			my $fake_entry = GNUpod::XMLhelper::mkfile({ add => { id => $id } }, { return=>1 });
			my $found = 0;
			foreach(GNUpod::XMLhelper::getpl_content($plname)) {
				if($_ eq $fake_entry) {
					$found++; last;
				}
			}
			GNUpod::XMLhelper::mkfile({ add => { id => $id } },{"plname"=>$plname}) unless $found;
		}
	}
}



## XML Handlers ##
sub newfile {
	$dupdb_normal{lc($_[0]->{file}->{title})."/$_[0]->{file}->{bitrate}/$_[0]->{file}->{time}/$_[0]->{file}->{filesize}"}= $_[0]->{file}->{id}||-1;

	#This is worse than _normal, but the only way to detect dups *before* re-encoding...
	$dupdb_lazy{lc($_[0]->{file}->{title})."/".lc($_[0]->{file}->{album})."/".lc($_[0]->{file}->{artist})}= $_[0]->{file}->{id}||-1;
	
	#Add podcast infos if it is an podcast
	if($_[0]->{file}->{podcastguid}) {
		$dupdb_podcast{$_[0]->{file}->{podcastguid}."\0".$_[0]->{file}->{podcastrss}}++;
	}
	$AWDB->KeepImage($_[0]->{file}->{dbid_1});
	GNUpod::XMLhelper::mkfile($_[0],{addid=>1});
}

sub newpl {
	GNUpod::XMLhelper::mkfile($_[0],{$_[2]."name"=>$_[1]});
}
##################


#### PODCAST START ####

#############################################################
# Calls curl to get files
sub PODCAST_fetch {
	my($url,$prefix) = @_;
	print "* [HTTP] Downloading $url ...\n";
	my $tmpout = GNUpod::FooBar::get_u_path($prefix,"");
	my $return = system("curl", "-s", "-L", "-o", $tmpout, $url);
	return{file=>$tmpout, status=>$return};
}

sub PODCAST_fetch_media {
	my($url,$prefix,$length) = @_;
	if ($opts{'podcast-cache-dir'}) {
	
		my @cachefilecandidates = ();
		my $deepcachefile = $opts{'podcast-cache-dir'}."/".PODCAST_get_sane_path_from_url($url , "");
		push @cachefilecandidates, $deepcachefile  if $deepcachefile;
		
		my $flatcachefile = $opts{'podcast-cache-dir'}."/".PODCAST_strictly_sanitze_path_element((split(/\//, $url))[-1], "cachefile");
		push @cachefilecandidates, $flatcachefile;

		foreach my $cachefile (@cachefilecandidates) {
			if ( -e $cachefile && -r $cachefile ) {
				my $sizedelta = int($length) - int((stat($cachefile))[7]) ;
				if ( ($length != 0) && (abs($sizedelta) > ($length * 0.05)) ) {
					print "* [HTTP] Not using cached file $cachefile ... (".abs($sizedelta)." bytes too ".($sizedelta > 0 ? "small" : "big").")\n";
				} else {
					print "* [HTTP] Using cached file $cachefile (size:".(stat($cachefile))[7].") ...".
						(($length != 0 && $sizedelta) ? " (even though it is ".abs($sizedelta)." bytes too " . ($sizedelta>0?"small":"big") . ")" : "")."\n";
					return {file=>$cachefile, status=>0};
				}
			}
		}
		print "* [HTTP] Downloading $url ...\n";
		my $return = system("curl", "-s", "-L", "--create-dirs", "-o" , $deepcachefile, $url);
		return {file=>$deepcachefile, status=>$return};
	}
	else {
		return PODCAST_fetch($url,$prefix);
	}
}

sub PODCAST_strictly_sanitze_path_element {
	my ($name,$default) = @_;
	$name =~ s/[^.0-9a-zA-z()_-]/_/g; # limit valid character set
	$name =~ s/^[.]*//g; #remove leading dots
	$name =~ s/[.]*$//g; #remove trailing dots (cause problems on windows i heard
	$name = $default unless $name; #default if empty
	return $name;
}
	

sub PODCAST_get_sane_path_from_url {
	my($uri,$default) = @_;
	my($scheme, $authority, $path, $query, $fragment) = $uri =~ m|(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?|;
	my @pathelements = ($authority, split (/\//, $path));
	my @cleanpathelements=();
	foreach my $pe ( @pathelements ) {
		push @cleanpathelements, PODCAST_strictly_sanitze_path_element($pe,'');
	}
	my $cleanpath =  join ("/", @cleanpathelements);
	$cleanpath =~ s|/[/]+|/|g; # collaps multiple /
	$cleanpath = $default  if ! $cleanpath;
	$cleanpath = $default  if $cleanpath eq "/";
	return $cleanpath;
}

#############################################################
#Eventer for START:
# -> Push array if we found a new item beginning
# -> Add '<foo bar=barz oink=yak />' stuff to the hash
# => Fillsup %podcast_infos
sub podcastStart {
	my($hr,$el,@it) = @_;
	my $hashref_key = $hr->{Base};
	undef($hr->{cdatabuffer});
	if($hr->{Context}[-2] eq "rss" &&
	   $hr->{Context}[-1] eq "channel" &&
		 $el eq "item") {
		push(@{$podcast_infos{$hashref_key}}, {});
	}
	elsif($hr->{Context}[-3] eq "rss" &&
	   $hr->{Context}[-2] eq "channel" &&
	   $hr->{Context}[-1] eq "item" &&
	   @it) {
		my $xref = GNUpod::XMLhelper::mkh($el,@it);
		${$podcast_infos{$hashref_key}}[-1]->{$el} ||= $xref->{$el};
	}
}

#############################################################
#Eventer for <foo>CONTENT</foo>
# => Fillsup %podcast_infos
sub podcastChar {
	my($hr,$el) = @_;
	$hr->{cdatabuffer} .= $el;
}

#############################################################
#Eventer for END
# => Fillsup %podcast_infos
sub podcastEnd {
	my($hr,$el) = @_;
	my $hashref_key = $hr->{Base};
	if(defined($hr->{cdatabuffer}) &&
	   $hr->{Context}[-3] eq "rss" &&
	   $hr->{Context}[-2] eq "channel" &&
	   $hr->{Context}[-1] eq "item") {
		${$podcast_infos{$hashref_key}}[-1]->{$el}->{"\0"} ||= $hr->{cdatabuffer};
	}
	undef($hr->{cdatabuffer});
}

#############################################################
#Eventer for START:
# -> Push array if we found a new item beginning
# -> Add '<foo bar=barz oink=yak />' stuff to the hash
# => Fillsup %podcast_channel_infos
sub podcastChannelStart {
	my($hr,$el,@it) = @_;
	my $hashref_key = $hr->{Base};
	$hr->{cdatabuffer} = undef;
	if($hr->{Context}[-1] eq "rss" &&
	   $el eq "channel") {
		push(@{$podcast_channel_infos{$hashref_key}}, {});
	}elsif($hr->{Context}[-2] eq "rss" &&
	   $hr->{Context}[-1] eq "channel" &&
	   $el ne "item") {
		if (@it) {
			my $xref = GNUpod::XMLhelper::mkh($el,@it);
			${$podcast_channel_infos{$hashref_key}}[-1]->{$el} ||= $xref->{$el};
		}
	}
}

#############################################################
#Eventer for <foo>CONTENT</foo>
# => Fillsup %podcast_channel_infos
sub podcastChannelChar {
	my($hr,$el) = @_;
	$hr->{cdatabuffer} .= $el;
}

#############################################################
#Eventer for END
# => Fillsup %podcast_channel_infos
sub podcastChannelEnd {
	my($hr,$el) = @_;
	my $hashref_key = $hr->{Base};
	if(defined($hr->{cdatabuffer}) &&
	   $hr->{Context}[-2] eq "rss" &&
	   $hr->{Context}[-1] eq "channel" &&
	   $el ne "item") {
		${$podcast_channel_infos{$hashref_key}}[-1]->{$el}->{"\0"} ||= $hr->{cdatabuffer};
	}elsif(defined($hr->{cdatabuffer}) &&
	   $hr->{Context}[-3] eq "rss" &&
	   $hr->{Context}[-2] eq "channel" &&
	   $hr->{Context}[-1] ne "item") {
		${$podcast_channel_infos{$hashref_key}}[-1]->{$hr->{Context}[-1]}->{$el}->{"\0"} ||= $hr->{cdatabuffer};
	}
	$hr->{cdatabuffer} = undef; # make sure it doesn't get added to the parent element as well
}

#############################################################
# This is the heart of our podcast support
#
sub resolve_podcasts {
	my(@xfiles) = @_;
	my @files = ();
	my $i = 0;
	
	my $env_is_okay = 1 if $opts{playlist} && $opts{'playlist-is-podcast'};
	
	foreach my $cf (@xfiles) {
		if (($cf =~ /^http:\/\//i) || ($cf =~ /^file:\/\//i)) {
			$i++;
			print "* [HTTP] Fetching Podcast #$i: $cf\n";
			
			unless($env_is_okay) {
				warn "! [!!!!] WARNING: This podcast may not appear on your iPod because you did not specify a podcast-playlist to use.\n";
				warn "! [!!!!]          Please use the options '--playlist' and '--playlist-is-podcast' while fetching podcasts.\n";
			}
			
			my $pcrss = PODCAST_fetch($cf, "/tmp/gnupodcast$i");
			if($pcrss->{status} or (!(-f $pcrss->{file}))) {
				warn "! [HTTP] Failed to download the file '$cf', curl exitcode: $pcrss->{status}\n";
				next;
			}
			#Add the stuff to %podcast_infos and unlink the file after this.
			eval {
				my $px = new XML::Parser(Handlers=>{Start=>\&podcastStart, Char=>\&podcastChar, End=>\&podcastEnd});
				$px->parsefile($pcrss->{file});
				my $py = new XML::Parser(Handlers=>{Start=>\&podcastChannelStart, Char=>\&podcastChannelChar, End=>\&podcastChannelEnd});
				$py->parsefile($pcrss->{file});
			};
			warn "! [HTTP] Error while parsing XML: $@\n" if $@;
			unlink($pcrss->{file}) or warn "Could not unlink $pcrss->{file}, $!\n";

			#Limit the number of podcasts to dowload.
			my @pods   = @{$podcast_infos{$pcrss->{file}}};
			my $flimit = int($opts{'podcast-files-limit'});
			if ($flimit > 0) {
				splice(@pods, $flimit);
			} elsif ($flimit < 0) {
				splice(@pods, 0, $flimit);
			}				
			$podcast_infos{$pcrss->{file}} = \@pods;

			$per_file_info{$pcrss->{file}}->{REAL_RSS} = $cf;
		}
		else {
			push(@files, $cf);
		}
	}

#	use Data::Dumper;
#	print Dumper(\%podcast_channel_infos);

	foreach my $key (keys(%podcast_infos)) {
		my $cref = $podcast_infos{$key};
		my $channel = $podcast_channel_infos{$key}[0]; # assuming for now that there's only one channel in the feed
		# get the artwork
		if (defined($opts{'podcast-artwork'})) {
			my $channel_image_url = ( $channel->{"itunes:image"}->{"href"} or
				$channel->{"image"}->{"url"}->{"\0"} ) ;
			if ( $channel_image_url ) {
				my $channel_image = PODCAST_fetch_media($channel_image_url, "/tmp/gnupodcast_image", 0);
				if($channel_image->{status} or (!(-f $channel_image->{file}))) {
					warn "! [HTTP] Failed to download $channel_image to ".$channel_image->{file}."\n";
				}
				else {
					add_image_to_awdb($channel_image->{file});
					if ( ! $opts{'podcast-cache-dir'} ) {
						unlink($channel_image->{file}) or warn "Could not unlink ".$channel_image->{file}.", $!\n";
					}
				}
			}
		}

		foreach my $podcast_item (@$cref) {
			my $c_title = $podcast_item->{title}->{"\0"};
			my $c_author = $podcast_item->{author}->{"\0"};
			my $c_iauthor = $podcast_item->{"itunes:author"}->{"\0"};
			my $c_rdate = $podcast_item->{pubDate}->{"\0"}; 
			my $c_desc  = $podcast_item->{description}->{"\0"};
			my $c_url   = $podcast_item->{enclosure}->{url};
			#We use the URL as GUID if there isn't one...			
			my $c_guid  = $podcast_item->{guid}->{"\0"} || $c_url;
			my $c_podcastrss = $per_file_info{$key}->{REAL_RSS};
			my $possible_dupdb_entry = $c_guid."\0".$c_podcastrss;
			
			if(length($c_guid) == 0 or length($c_podcastrss) == 0 or length($c_url) == 0) {
				warn "! [HTTP] '$c_podcastrss' is an invalid podcast item (No URL/RSS?)\n";
				next;
			}
			elsif($dupdb_podcast{$possible_dupdb_entry}) {
				warn "! [HTTP] Podcast $c_url ($c_title) exists, no need to download this file\n";
				next;
			}		
			my $rssmedia = PODCAST_fetch_media($c_url, "/tmp/gnupodcast_media", $podcast_item->{enclosure}->{length});
			if($rssmedia->{status} or (!(-f $rssmedia->{file}))) {
				warn "! [HTTP] Failed to download $c_url to $rssmedia->{file}\n";
				next;
			}
			
			$per_file_info{$rssmedia->{file}}->{UNLINK}    = 1 unless $opts{'podcast-cache-dir'};  # Remove tempfile if not caching
			$per_file_info{$rssmedia->{file}}->{ISPODCAST} = 1;  # Triggers mediatype fix
			
			# Set information/tags from XML-File
			$per_file_info{$rssmedia->{file}}->{podcastguid} = $c_guid;
			$per_file_info{$rssmedia->{file}}->{podcastrss}  = $c_podcastrss;
			$per_file_info{$rssmedia->{file}}->{title}       = $c_title   if $c_title;
			$per_file_info{$rssmedia->{file}}->{artist}      = $c_author  if $c_author;
			$per_file_info{$rssmedia->{file}}->{artist}      = $c_iauthor  if $c_iauthor;
			$per_file_info{$rssmedia->{file}}->{desc}        = $c_desc    if $c_desc;
			$per_file_info{$rssmedia->{file}}->{releasedate} = int(Date::Parse::str2time($c_rdate))+MACTIME    if $c_rdate;
			
			push(@files,$rssmedia->{file});
		}
	}
	
	return @files;
}

#### PODCAST END ####


###############################################################
# Check if the file is a duplicate
sub checkdup {
 my($fh, $from_lazy) = @_;
 
 return  $dupdb_lazy{lc($_[0]->{title})."/".lc($_[0]->{album})."/".lc($_[0]->{artist})}
   if $from_lazy;
   
 return $dupdb_normal{lc($fh->{title})."/$fh->{bitrate}/$fh->{time}/$fh->{filesize}"};
}


################################################################
#Sighandler
sub handle_int {
 if($int_count) {
  warn "RECEIVED SIGINT (CTRL+C): gnupod_addsong.pl is still working! hit CTRL+C again $int_count time(s) to quit.\n";
  $int_count--;
 }
 else {
  warn "..wait.. cleaning up..\n";
 }
}


###############################################################
# Basic help
sub usage {
my($rtxt) = @_;
die << "EOF";
$rtxt
Usage: gnupod_addsong.pl [-h] [-m directory] File1 File2 ...

   -h, --help                       display this help and exit
       --version                    output version information and exit
   -m, --mount=directory            iPod mountpoint, default is \$IPOD_MOUNTPOINT
   -r, --restore                    Restore the iPod (create a new GNUtunesDB from scratch)
   -d, --duplicate                  Allow duplicate files
   -p, --playlist=string            Add songs to this playlist, can be used multiple times
       --playlist-is-podcast        Set podcast flag for playlist(s) created using '--playlist'
       --podcast-artwork            Download and install artwork for podcasts from their channel.
       --podcast-cache-dir=string   Set a directory in which podcast media files will be cached.
       --podcast-files-limit=int    Limit the number of files that are downloaded.
                                    0 = download all (default), -X = download X oldest items, X = download X newest items
       --disable-v1                 Do not read ID3v1 Tags (MP3 Only)
       --disable-v2                 Do not read ID3v2 Tags (MP3 Only)
   -x  --decode=pcm|mp3|aac|aacbm   Convert FLAC Files to WAVE/MP3 or AAC 'on-the-fly'. Use '-e' to specify a quality/bitrate
   -x  --decode=video               Convert .avi Files into iPod video 'on-the-fly' (needs ffmpeg with AAC support)
   -e  --reencode=int               Reencode MP3/AAC files with new quality 'on-the-fly'
                                    (0 = Good .. 9 = Bad)
                                    You may be able to save some space if you do not need
                                    crystal-clear sound ;-)
   -t  --set-title=string           Set Title  (Override ID3 Tag)
   -a  --set-artist=string          Set Artist (Override ID3 Tag)
   -l  --set-album=string           Set Album  (Override ID3 Tag)
   -g  --set-genre=string           Set Genre  (Override ID3 Tag)
       --set-rating=int             Set Rating
       --set-playcount=int          Set Playcount
       --set-songnum                Override 'Songnum/Tracknum' field
   -b  --set-bookmarkable           Set this song as bookmarkable (= Remember position)
       --set-shuffleskip            Exclude this file in shuffle-mode
       --set-compilation            Mark songs as being part of a compilation
       --min-vol-adj=int            Minimum volume adjustment allowed by ID3v2.4 RVA2 tag
       --max-vol-adj=int            Maximum ditto.  The volume can be adjusted in the range
                                    -100% to +100%.  The default for these two options is 0,
                                    which effectively ignored the RVA2 tag.
       --artwork=FILE               Use FILE as album cover


Report bugs to <bug-gnupod\@nongnu.org>
EOF
}

sub version {
die << "EOF";
gnupod_addsong.pl (gnupod) ###__VERSION__###
Copyright (C) Adrian Ulrich 2002-2008

This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

EOF
}

