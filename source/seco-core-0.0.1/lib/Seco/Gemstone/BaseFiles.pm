package Seco::Gemstone::BaseFiles;
use strict;
use warnings;
use GemInstaller;
use FindBin qw/$Bin/;
use File::Compare;
use Seco::Gemstone::Logger qw/log/;

sub new {
    my $class = shift;
    my $local = shift;
    my $self = { _instances => {}, files => {},
                 installer => GemInstaller->new($local) };
    bless $self, $class;
    $self->setup;
    return $self;
}

sub setup {
    die "ERROR: You must provide your own setup() method";
}

sub get_files {
    my $self = shift;
    return sort keys %{$self->{files}};
}

sub sort_files {
    my $self = shift;
    my $files = $self->{files};

    my @result =
      map { $_->[1] }
        sort { $files->{$b->[0]}{priority} <=> $files->{$a->[0]}{priority}
                 or $a->[0] cmp $b->[0] }
          map { my $f = $_; $f =~ s/##.*//; [$f, $_] } @_;
    
    return @result;
}

sub add {
    my $self = shift;
    my $name = shift;
    my $installer = $name; $installer =~ s/[-.]/_/g;
    my ($outdir, $procdir) = ("$Bin/../out", "$Bin/../processed");

    my %entry = (installer => $installer, 
		 constructor => 'Seco::Gemstone::Constructor',
                 verbose_failure => 1,
                 verify => sub { @_ > 0 },
                 priority => 0,
		 comparator => sub {
                     my $filename = shift;
		     return compare("$outdir/$filename", "$procdir/$filename");
		 },
		 @_); # override defaults

    $self->{files}{$name} = \%entry;
}

sub get_constructor {
    my ($self, $rule_name) = @_;
    my $entry = $self->{files}{$rule_name};
    return unless $entry;

    my $constructor = $entry->{constructor};
    # Only create one instance for each constructor type
    my $c = $self->{_instances}{$constructor};
    return $c if $c;

    my ($package_name, $args) = $constructor =~ /^(Seco::Gemstone::\w+)(?:\(([^\)]+)\))?$/;
    eval "use $package_name";
    my @args;
    if (defined $args) {
        @args = $args =~ /(?:^|\s*,\s*)(\w+)\s*=>\s*([^\s,]+)/g;
    }
    $c = $package_name->new(@args);
    return $self->{_instances}{$constructor} = $c; # store it for later use
}

sub needs_to_run {
    my ($self, $filename) = @_;
    my ($instance, $rule);
    if ($filename =~ /^(.*)##(.*)$/) {
        $rule = $1;
        $instance = $2;
    } else {
        $rule = $filename;
        $instance = "DEFAULT";
    }
    my $entry = $self->{files}{$rule};
    return 1 unless $entry;
    my $cmp = $entry->{comparator}->($filename, $rule, $instance);
    return 1 if $cmp == 1 || $cmp == -1 && $! =~ /^No such file/;
    if ($cmp == -1) {
	log("err", "$filename ($rule) $!");
	return 1;
    }
    return 0;
}

sub install {
    my ($self, $file) = @_;
    my $gem_inst = $self->{installer};

    my ($instance_msg, $instance);
    if ($file =~ /^(.*)##(.*)$/) {
        $file = $1;
        $instance = $2;
        $instance_msg = " (Instance $instance)";
    } else {
        $instance = "DEFAULT";
        $instance_msg = "";
    }
    $gem_inst->{instance} = $instance;

    my $entry = $self->{files}{$file};
    return unless $entry;

    log("info", "Installer: $file$instance_msg");
    my $inst_method = \&{"GemInstaller::" . $entry->{installer}};
    my $result = \&$inst_method($gem_inst);
    return $result;
}

sub verify {
    my ($self, $file, @data) = @_;
    $file =~ s/##.*$//;

    my $entry = $self->{files}{$file};
    unless ($entry) {
        log("warning", "Unknown file: $file");
        return 0;
    }
    my $verifier = $entry->{verify};
    my $is_ok = $verifier->(@data);
    if (not $is_ok and $entry->{verbose_failure}) {
        log("warning", "$file: fails verification");
    }
    return $is_ok;
}

1;
