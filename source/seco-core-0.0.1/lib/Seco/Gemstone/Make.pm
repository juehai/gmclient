package Seco::Gemstone::Make;

use strict;
use Sys::Hostname;
use FindBin qw/$Bin/;
use Cwd;

use Seco::Gemstone::Utils qw/gem_all_groups gem_read_raw_file 
    gem_move read_file write_file motd/;
use Seco::Gemstone::Config qw/get_type get_multicast_dir/;
use Seco::Gemstone::Logger qw/log/;

=head1 NAME

Seco::Gemstone::Make - Make and install gemstone managed files

=head1 DESCRIPTION

This module will fetch all the gemstone managed config files (groups.cf,
transforms/*, raw/* and build the corresponding files based on the
transforms that apply to the machine we are running on.

=over 4

=item Seco::Gemstone::Make->new

Create a new Seco::Gemstone::Make object. You shouldn't need more than one
of these babies, and you'll probably call it like:

    $gem = Seco::Gemstone::Make->new;
    $gem->make

=cut
sub new {
    my $class = shift;
    $|++;

eval {
    require Seco::AwesomeRange;
    import Seco::AwesomeRange qw/expand_range range_set_altpath/;
    log("debug", "Using Seco::AwesomeRange");
};
if ($@) {
    require Seco::Range;
    import Seco::Range qw/expand_range range_set_altpath/;
    log("warning", "Can't find AwesomeRange - using Seco::Range");
}


    range_set_altpath("$Bin/..");

    return bless {
                  adminhost => "adminhost",
                  test_from => undef,
                  force_refresh => [],
                  localrun => undef,
                  multicast_allowed => 1,
                  groups => [],
                  updated_files => [],
                  debug => 1,
                  myname => hostname(),
                  rules => {},
                  files => undef
                 }, $class;
}

sub _init {
    my $self = shift;

    my $type = get_type();
    unshift(@INC, "$Bin/../conf/installations/$type");
    require GemFiles;
    $self->{files} = GemFiles->new($self->{localrun});
}

=item $gem->make

Get new files, generate the files, and install the files that have changed 

=cut
sub make {
    my $self = shift;

    # Setup path and curdir
    my $path = $ENV{PATH};
    my $curdir = cwd();
    $ENV{PATH}="/usr/local/bin:/usr/local/sbin:/bin:/usr/bin:/usr/sbin:/sbin";
    chdir("$Bin/..");

    # Get a lock
    die "ERROR: Failed to get a lock" unless $self->get_lock;

    # And do our stuff
    if ($self->{test_from}) {
        # get files from test_from
        $self->get_files_from($self->{test_from});
        $self->{localrun} = 1; # disable manifest checking
    } else {
        $self->get_files unless $self->{localrun};
    }
    $self->_init;
    $self->gen_files;
    die "ERROR: insufficient disk space on /.\n" 
        unless $self->has_enough_space("/");
    my $this_dir = cwd();
    die "ERROR: insufficient disk space on $this_dir\n" 
        unless $self->has_enough_space(".");
    $self->find_updated_files;
    $self->install;
    $self->unlock;
    # Restore path and dir
    $ENV{PATH} = $path;
    chdir($curdir);
}

sub get_files_from {
    my ($self, $from) = @_;
    if ($from !~ /:/ and $from !~ m{/$}) {
        $from .= "/"; # if it's a local path make sure we have a dir name
    }
    system("rm -rf conf/* raw/* transforms/*");
    $self->debug("Getting files from $from");
    $self->_rsync_preserve($from, "$Bin/../");
    if ($?) {
        die "ERROR: cannot get files from $from\n";
    }
}

sub unlock {
    unlink "gemclient.lock";
}

sub _get_proc_name {
    my $pid = shift;
    if ($^O eq "linux") {
        return "" unless -e "/proc/$pid/stat";
        my $stat = read_file("/proc/$pid/stat");
        $stat =~ /\(([^)]+)\)/ or return;
        return $1;
    } elsif ($^O eq "freebsd") {
        return "" unless -e "/proc/$pid/cmdline";
        my $cmdline = read_file("/proc/$pid/cmdline");
        my $name = (split('\0', $cmdline))[1];
	$name = (split('\0', $cmdline))[2] if ($name =~ m/^-w$/);
        $name =~ s{.*/}{};
        return $name;
    }

    die "ERROR: unsupported OS: $^O";
}

=item $gem->get_lock

Make sure we only run one copy of us at a time.

=cut
sub get_lock {
    my $self = shift;

    my $current_pid = readlink("gemclient.lock");
    if ($current_pid) {
	my $name = _get_proc_name($current_pid);
	$self->debug("Lock file says pid $current_pid ($name) owns the lock.");
	if ($name ne "run" and $name ne "gemclient") {
	    $self->debug("Stale lock - removing.");
	    unlink("gemclient.lock");
	}
    }
    symlink $$, "gemclient.lock";
}

=item $gem->has_enough_space

Return whether we have enough space to perform a successful run

=cut
sub has_enough_space {
    my $self = shift;
    my $dir = shift;
    my $df_output = `df -k $dir`;
    my ($free_space) = ($df_output =~ m{^(?:/dev/\S+|proc|-)\s+\d+\s+\d+\s+(\d+)}m);
    $self->debug("$free_space k available ($dir)") if $free_space <= 50 * 1024;
    return $free_space > 50 * 1024;
}

=item $gem->adminhost

Specify an alternative adminhost to use during this run. Usage:

  $gem->adminhost("pain");

=cut
sub adminhost {
    my ($self, $admin) = @_;
    $self->{adminhost} = $admin if $admin;
    return $self->{admihost};
}

=item $gem->force_refresh

Force a refresh of the given files, even if we thing they don't need to be updated.

  $gem->force_refresh("passwd", "sudoers"); # force refresh of /etc/passwd, /etc/sudoers

=cut
sub force_refresh {
    my ($self, @files) = @_;

    $self->{force_refresh} = [@files] if @files;
    return @{$self->{force_refresh}};
}

=item $gem->test_from

Specify an rsync path that we should use to get the data from

Note that if you set this, adminhost will be ignored.

=cut

sub test_from {
    my ($self, $from) = @_;
    $self->{test_from} = $from if defined $from;
    return $self->{test_from};
}

=item $gem->localrun

Use to test the current local configuration files. This Seco::Gemstone::Make
object will not rsync its config files from the admin, and it won't perform
sig verification.

=cut
sub localrun {
    my ($self, $localrun) = @_;
    $self->{localrun} = $localrun if defined $localrun;
    return $self->{localrun};
}

sub multicast_allowed {
    my ($self, $multicast_allowed) = @_;
    $self->{multicast_allowed} = $multicast_allowed 
        if defined $multicast_allowed;
    return $self->{multicast_allowed};
}

sub get_files_using_multicast {
    my $self = shift;
    my $got_files = 0;
    my $multi = get_multicast_dir();
    if (defined $multi and -d $multi) {
        my $timestamp = "$multi/timestamp";
        my $mtime = (stat $timestamp)[9];
        if ((time() - $mtime) <= (35 * 60)) {
            $self->debug("Getting files from localhost:$multi");
            $self->_rsync("$multi/current/conf/", "$Bin/../conf/");
            $got_files = $? == 0;
            $self->_rsync("$multi/current/raw/", "$Bin/../raw/");
            $got_files &&= $? == 0;
            $self->_rsync("$multi/current/transforms/", "$Bin/../transforms/");
            $got_files &&= $? == 0;
            $self->_rsync("$multi/current/.manifest.md5sum", 
            "$Bin/../.manifest.md5sum");
            $got_files &&= $? == 0;
            $self->debug("Sucessfully got all files using multicast data.")
                if $got_files;
        } else {
            $self->debug("Multicast data is too old: " . localtime($mtime));
        }
    }
    return $got_files;
}

=item $gem->get_files

Get groups.cf, hosts.cf, transforms/*, raw/* from the gemstone repository.

=cut
sub get_files {
    my $self = shift;
    my $multicast_allowed = $self->{multicast_allowed};

    if ($multicast_allowed) {
        my $got_files = $self->get_files_using_multicast;
        return if $got_files;
    }

    my $adminhost = $self->{adminhost};
    $self->debug("Getting files from ${adminhost}::gemserver.");
    $self->_rsync("${adminhost}::gemserver/conf/", "$Bin/../conf/");
    $self->_rsync("${adminhost}::gemserver/raw/", "$Bin/../raw/");
    $self->_rsync("${adminhost}::gemserver/transforms/", "$Bin/../transforms/");
    $self->_rsync("${adminhost}::gemserver/.manifest.md5sum",
        "$Bin/../.manifest.md5sum");
}

# never call this with args that contain shell parsable characters
# to make it shell safe replace @args with: .join ' ',map{quotemeta}@args
sub _rsync {
    my ($self, @args) = @_;
    my $cmd = "ulimit -t 600; nice rsync --delete -a @args";
    system($cmd);
}

sub _rsync_preserve {
    my ($self, @args) = @_;
    my $cmd = "ulimit -t 600; nice rsync -a @args";
    system($cmd);
}

=item $gem->gen_files

Generate our files

=cut
sub gen_files {
    my $self = shift;
    $self->find_my_groups;
    $self->apply_transforms;
}

=item $gem->find_my_groups

Find which groups include our machine. TODO: Cache this and use the
cached values if groups.cf has not changed.

=cut
sub find_my_groups {
    my $self = shift;
    my @my_groups;

    my @groups = gem_all_groups();
    for my $group (@groups) {
	push @my_groups, $group if $self->belongs_to_group($group);
    }
    $self->{groups} = \@my_groups;
    $self->debug("My groups: "  . join(",", @my_groups));

    die "ERROR: Not listed in groups.cf for any group at all.\n" unless @my_groups;
    motd("groups","DEFAULT @my_groups");
}

=item $gem->belongs_to_group($group_name)

Returns true if the current machine belongs to the group $group_name

=cut
sub belongs_to_group {
    my ($self, $group) = @_;
    my $name = $self->{myname};

    my @nodes = expand_range("%GROUPS:$group");
    for (@nodes) {
	return 1 if $name eq $_;
    }
    return 0;
}

=item $gem->apply_transforms

Apply the transforms that apply to us, based on what groups we belong to. And do
this in order.

=cut
sub apply_transforms {
    my $self = shift;

    $self->debug("Applying transforms");
    # create the "rules" files
    $self->create_rules;
    # and do something very smart with it
    $self->apply_rules;
}

sub create_rules {
    my $self = shift;

    $self->{rules} = {};
    $self->add_rule("DEFAULT");
    for (@{$self->{groups}}) {
	$self->add_rule($_);
    }

}

sub add_rule {
    my ($self, $transform) = @_;
    my $rules = $self->{rules};

    open my $fh, "<$Bin/../transforms/$transform" or do {
	return;
    };

    my $cur_key;
    while (<$fh>) {
	s/^#.*//; s/\s+$//;
	next unless /\S/;

	if (/^\s/ && $cur_key) {
	    s/^\s+//;
	    push @{$rules->{$cur_key}}, $_;
	} else { # New key
	    $cur_key = $_;
	}
    }
    close $fh;
}

sub apply_rules {
    # generate the files to be installed on the machine
    my $self = shift;
    my %rules = %{$self->{rules}};
    mkdir "$Bin/../out" unless -d "$Bin/../out";
    mkdir "$Bin/../processed" unless -d "$Bin/../processed";

    for my $rule (sort keys %rules) {
	$self->apply_rule($rule, $rules{$rule});
    }
    1;
}

sub apply_rule {
    my ($self, $file_name, $rules) = @_;

    my $gem_files = $self->{files};
    my $constructor = $gem_files->get_constructor($file_name);
    unless ($constructor) {
        log("warning", "$file_name does not have a constructor.");
	return;
    }

    my $results = $constructor->construct($file_name, @$rules);
    if (scalar keys %$results > 2 and not @{$results->{DEFAULT}}) {
        delete $results->{DEFAULT};
    }
    while (my ($instance, $data) = each(%$results)) {
        next if $instance =~ /^\./;
        my $suffix = $instance eq "DEFAULT" ? "" : "##$instance";
        if ($gem_files->verify($file_name, @$data)) {
            my $contents = join("\n", @$data) . "\n";
            write_file("$Bin/../out/$file_name$suffix", $contents);
        } else {
            if ($file_name eq "passwd" and $instance eq "DEFAULT") {
                # this is too serious
                log("crit", "passwd doesn't pass our checks!\n");
                die "ERROR: passwd doesn't pass our checks!\n";
            }
        }
    }
}

=item $gem->getmostrecent

Return the most recent updated file

=cut
sub getmostrecent {
    my $self = shift;
    return $self->{mostrecent} || 0; 
}


=item $gem->find_updated_files

Find which files have been changed since our last invocation

Processed files are in processed/*, generated files are in out/*
Once a generated file has been processed it's moved to processed/*
so generated files that are different from what's been processed
are the ones that should be installed.

You can also force the refresh of certain files, or even all files, by calling
$gem->force_refresh() with a list of files, or with the magic name 'all'

=cut
sub find_updated_files {
    my $self = shift;
    my @updated;

    # Get list of generated files
    my @registered_files = $self->{files}->get_files;
    my %registered_files; @registered_files{@registered_files} = undef;
    my @files_in_dir = $self->get_files_in_dir("out");
    my @gen_files = grep
      { my $f = $_; $f =~ s/##.*//; exists $registered_files{$f} }
        @files_in_dir;

    my @processed_files = $self->get_files_in_dir("processed");

    my %force; @force{@{$self->{force_refresh}}} = ();
    if (exists $force{all}) {
	$self->{updated_files} = \@gen_files;
	return;
    }

    for my $file (@gen_files) {
	next unless exists $force{$file} or
	  $self->{files}->needs_to_run($file);
	push @updated, $file;
    }
    $self->{updated_files} = \@updated;
}

sub get_files_in_dir {
    my ($self, $dir) = @_;
    mkdir "$Bin/../$dir", 0777; # ignore the error
    opendir(my $h, "$Bin/../$dir") or die "$Bin/../$dir $!";
    my @gen_files = grep { ! /^\./ } readdir($h);
    closedir($h);
    return sort @gen_files;
}

=item $gem->install

Install the generated files that have changed since our previous invocation.

=cut
sub install {
    my $self = shift;
    my $gem_files = $self->{files};
    my @files = @{$self->{updated_files}};
    @files = $self->{files}->sort_files(@files);
    log("notice", "Running installer for " . join(",", @files));
    for my $file (@files) {
	$gem_files->install($file) and
	    gem_move("out/$file", "processed/$file");
    }
}

=item $gem->debug($msg)

Print a debugging message if $self->{debug} is true

=cut
sub debug {
    my ($self, $msg) = @_;
    return unless $self->{debug};

    log("debug", $msg);
}

=back


=head1 AUTHOR

Daniel Muino <dmuino@yahoo-inc.com>

=cut
1;
