#!/usr/bin/perl -w
# -*- mode: Perl; tab-width: 4; -*-
#
# create-finkdb.pl - generate a runtime index of Fink's package database
# Copyright (c) 2001 Christoph Pfisterer
# Copyright (c) 2001-2007 The Fink Package Manager Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

$| = 1;
use 5.008_001;  # perl 5.8.1 or newer required
use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Basename;
use File::Slurp;
use Text::CSV_PP;

our $topdir;
our $fink_version;

BEGIN {
	$topdir = dirname(abs_path($0));
	chomp($fink_version = read_file($topdir . '/fink/VERSION'));

	my $finkversioncontents = read_file($topdir . '/fink/perlmod/Fink/FinkVersion.pm.in');
	$finkversioncontents =~ s/\@VERSION\@/$fink_version/gs;
	write_file($topdir . '/fink/perlmod/Fink/FinkVersion.pm', $finkversioncontents);
};

### now load the useful modules

use lib qw($topdir/fink/perlmod);
use Fink::Services qw(&read_config &latest_version);
use Fink::Config qw(&set_options);
use Fink::Package;
use Fink::Command qw(rm_f);
use File::Path;
use File::stat;
use POSIX qw(strftime);
use Time::HiRes qw(usleep);
use Data::Dumper;
use IO::Handle;
use XML::Writer;

use Encode;
use Text::Iconv;
use Getopt::Long;

$Data::Dumper::Deepcopy = 1;

use vars qw(
	$debug
	$trace
	$wanthelp

	$csv
	$iconv
	$last_updated
	$temppath

	$releases
);

$csv          = Text::CSV_PP->new({ binary => 1 });
$debug        = 0;
$trace        = 0;
$iconv        = Text::Iconv->new("UTF-8", "UTF-8");
$temppath     = $topdir . '/work';
$last_updated = time;

# process command-line
GetOptions(
	'help'       => \$wanthelp,
	'temppath=s' => \$temppath,
	'debug'      => \$debug,
	'trace'      => \$trace,
) or &die_with_usage;

$debug++ if ($trace);

&die_with_usage if $wanthelp;

# get the list of distributions to scan
{
	my $distributions;

	print "- parsing distribution/release information\n";

	open (GET_DISTRIBUTIONS, $topdir . '/php-lib/get_distributions.php |') or die "unable to run $topdir/php-lib/get_distributions.php: $!";
	my @keys = parse_csv(scalar(<GET_DISTRIBUTIONS>));

	while (my $line = <GET_DISTRIBUTIONS>)
	{
		my @values = parse_csv($line);
		my $entry = make_hash(\@keys, \@values);
		my $id = $entry->{'id'};
		$distributions->{$id} = $entry;
	}
	close(GET_DISTRIBUTIONS);

	open (GET_RELEASES, $topdir . '/php-lib/get_distributions.php -r |') or die "unable to run $topdir/php-lib/get_distributions.php -r: $!";
	@keys = parse_csv(scalar(<GET_RELEASES>));

	while (my $line = <GET_RELEASES>) 
	{
		my @values = parse_csv($line);
		my $entry = make_hash(\@keys, \@values);
		my $id = $entry->{'id'};

		print "  - found $id\n" if ($debug);

		my $distribution_id = delete $entry->{'distribution_id'};
		$distributions->{$distribution_id} = {} unless (exists $distributions->{$distribution_id});
		$entry->{'distribution'} = $distributions->{$distribution_id};

		$releases->{$id} = $entry;
	}
	close (GET_RELEASES);
}

print Dumper($releases), "\n" if ($trace);

for my $release (sort keys %$releases)
{
	next unless ($release->{'issupported'});

	print "- checking out $release\n";
	check_out_release($releases->{$release});

	print "- indexing $release\n";
	index_release_to_xml($releases->{$release});

	#exit 1;
}

sub check_out_release {
	my $release = shift;
	my $release_id = $release->{'id'};

	my $tag = 'release_' . $release->{'version'};
	$tag =~ s/\./_/gs;
	if ($tag eq "release_current")
	{
		$tag = 'HEAD';
	}

	my $checkoutroot = $temppath . '/' . $release_id . '/fink';
	my $workingdir   = $checkoutroot;

	my @command = (
		'cvs',
		'-d', ':pserver:anonymous@fink.cvs.sourceforge.net:/cvsroot/fink',
		'checkout',
		'-r', $tag,
		'-d', 'dists',
		$release->{'distribution'}->{'rcspath'}
	);

	if (-e $checkoutroot . '/dists/CVS/Repository')
	{
		chomp(my $repo = read_file($checkoutroot . '/dists/CVS/Repository'));
		if ($repo eq $release->{'distribution'}->{'rcspath'})
		{
			@command = ( 'cvs', 'update', '-r', $tag );
			$workingdir = $checkoutroot . '/dists';
		} else {
			rmtree($checkoutroot . '/dists');
		}
	}

	run_command($workingdir, @command);
}

sub index_release_to_xml {
	my $release = shift;
	my $release_id = $release->{'id'};

	my $tree = $release->{'type'};
	$tree = 'stable' if ($tree eq 'bindist');
	my $basepath = get_basepath($release);

	undef $Fink::Package::packages;

	open(OLDOUT, ">&STDOUT");
	open(OLDERR, ">&STDERR");
	if ($trace)
	{
		# temporarily redirect stdout to stderr
		open(STDOUT, ">&STDERR") or die "can't dup STDERR: $!";
	} else {
		# temporarily ignore stdout/stderr
		open(STDOUT, ">/dev/null") or die "can't ignore STDOUT: $!";
		open(STDERR, ">/dev/null") or die "can't ignore STDERR: $!";
	}

	# keep 'use strict' happy
	select(OLDOUT); select(STDOUT);
	select(OLDERR); select(STDERR);

	# simulate a fink.conf; there's no actual file, so don't save() it
	my $config = Fink::Config->new_from_properties({
		'basepath'     => $basepath,
		'trees'        => "$tree/main $tree/crypto",
		'distribution' => $release->{'distribution'}->{'name'},
		'architecture' => $release->{'distribution'}->{'architecture'},
	});

	# omit actual locally-installed fink if it is present
	set_options({exclude_trees=>[qw/status virtual/]});
	
	# load the package database
	Fink::Package->load_packages();

	# put STDOUT back
	open(STDOUT, ">&OLDOUT");
	if (not $trace)
	{
		# we ignored STDERR, put it back
		open(STDERR, ">&OLDERR");
	}

	### loop over packages

	my ($package, $po, $version, $vo);
	my ($maintainer, $email, $desc, $usage, $parent, $infofile, $infofilechanged);
	my ($v, $s, $key, %data, $expand_override);

	foreach $package (Fink::Package->list_packages()) {
		$po = Fink::Package->package_by_name($package);
		next if $po->is_virtual();
		$version = &latest_version($po->list_versions());
		$vo = $po->get_version($version);
		
		# Skip splitoffs
		#next if $vo->has_parent();
	
		# get info file
		$infofile = $vo->get_info_filename();
		if ($infofile) {
			my $sb = stat($infofile);
			$infofilechanged = strftime "%Y-%m-%d %H:%M:%S", localtime $sb->mtime;
			$infofile =~ s,$basepath/fink/dists/,,;
		}
		
		# gather fields
	
		$maintainer = $vo->param_default("Maintainer", "(not set)");
	
		# Always show %p as '/sw'
		$expand_override->{'p'} = '/sw';
	
		$desc = $vo->param_default_expanded('DescDetail', '',
			expand_override => $expand_override,
			err_action => 'ignore'
		);
		chomp $desc;
		$desc =~ s/\s+$//s;
		#$desc =~ s/\n/\\n/g;
	 
		$usage = $vo->param_default_expanded('DescUsage', '',
			expand_override => $expand_override,
			err_action => 'ignore'
		);
		chomp $usage;
		$usage =~ s/[\r\n\s]+$//s;
		#$usage =~ s/\n/\\n/g;
	
		my $package_info = {
			name            => $vo->get_name(),
			version         => $vo->get_version(),
			revision        => $vo->get_revision(),
			epoch           => $vo->get_epoch(),
			descshort       => $vo->get_shortdescription(),
			desclong        => $desc,
			descusage       => $usage,
			maintainer      => $maintainer,
			license         => $vo->get_license(),
			homepage        => $vo->param_default("Homepage", ""),
			section         => $vo->get_section(),
			parentname      => $vo->has_parent()? $vo->get_parent()->get_name():undef,
			infofile        => $infofile,
			infofilechanged => $infofilechanged,
			last_updated    => $last_updated,
		};
	
		for my $key (keys %$package_info) {
			#$package_info->{$key} =~ s/(\x{ca}|\x{a8}|\x{e96261})/ /gs if (defined $package_info->{$key});
			$package_info->{$key} = encode_utf8($package_info->{$key}) if (defined $package_info->{$key});
		}

		print "  - found package ", package_id($package_info), "\n" if ($debug);
	}
}

# get the basepath for a given release
sub get_basepath {
	my $release = shift;

	return $temppath . '/' . $release->{'id'};
}

# run a command in a work directory
sub run_command {
	my $workingdir = shift;
	my @command = @_;

	mkpath($workingdir);

	my $fromdir = getcwd();
	print "  - changing directory to $workingdir\n" if ($trace);
	chdir($workingdir);

	print "  - running: @command\n" if ($debug);
	open(RUN, "@command |") or die "unable to run @command: $!";
	while (<RUN>) {
		print "  - " . $_ if ($trace);
	}
	close(RUN);

	print "  - changing directory to $fromdir\n" if ($trace);
	chdir($fromdir);
}

# create a package ID from package information
# this needs to be kept in sync with php-lib/finkinfo.inc
sub package_id
{
	my $package = shift;

	my $id = $package->{'name'};
	if ($package->{'epoch'})
	{
		$id .= '-' . $package->{'epoch'};
	}
	if (exists $package->{'version'})
	{
		if ($package->{'epoch'})
		{
			$id .= ':' . $package->{'version'};
		} else {
			$id .= '-' . $package->{'version'};
		}
	}
	$id .= '-' . $package->{'revision'} if (exists $package->{'revision'});

	return $id;
}

# turn two sets of array references into key => value pairs
sub make_hash {
	my $keys   = shift;
	my $values = shift;

	my $return;
	for my $index ( 0 .. $#$keys ) {
		$return->{$keys->[$index]} = $values->[$index];
		if ($values->[$index] eq "")
		{
			$return->{$keys->[$index]} = undef;
		}
	}

	return $return;
}

# parse a csv line
sub parse_csv {
	my $row = shift;
	chomp($row);
	if ($csv->parse($row))
	{
		return $csv->fields();
	} else {
		warn "unable to parse '$row'\n";
	}
	return [];
}

sub print_lucene_journal {
	my $handle  = shift;
	my $package = shift;

	print $handle "# ", join('-', $package->{'rel_id'}, $package->{'epoch'}, $package->{'name'}, $package->{'version'}, $package->{'revision'}), "\n";
	print $handle $package->{'pkg_id'}, "\n";
}

sub die_with_usage {
    die <<EOMSG;
Usage: $0 [options]

Options:
  --distribution
  --release
  --architecture
  --lucene
  --indexpath
  --help

'distribution' is the distribution identifier (e.g. '10.4' or '10.2-gcc3.3')
'release' is either a release version (e.g. 0.6.4) for bindists or the strings
  'unstable' or 'stable'
'architecture' is either 'powerpc' or 'i386'

If 'lucene' is set, and an index path is provided, dump will create an
index for a lucene search engine indexer.
EOMSG
}

exit 0;


# vim: ts=4 sw=4 noet
