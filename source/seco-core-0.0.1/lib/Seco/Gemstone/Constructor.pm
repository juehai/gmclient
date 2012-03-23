package Seco::Gemstone::Constructor;

use strict;

eval {
    require Seco::AwesomeRange;
    import Seco::AwesomeRange qw/expand_range range_set_altpath/;
};
if ($@) {
    require Seco::Range;
    import Seco::Range qw/expand_range range_set_altpath/;
}

use Seco::Gemstone::Utils qw/gem_read_raw_file gem_read_gzip_raw_file 
    get_rel_glob expand_vars read_file/;
use Seco::Gemstone::Logger qw/log/;

sub new {
    my $class = shift;
    my $self;
    $self = bless {}, $class unless ref $class;
    return $self;
}

sub construct { 
    my ($self, $rule_name, @rules) = @_;
    my %instances = ('DEFAULT' => [], '.CURRENT INSTANCE.' => 'DEFAULT');
    my $i = 0;
    for (@rules) {
        $i++;                   # to warn about 'eof' and ignoring rules
        chomp;
        last if /^eof/;
        next if /^\s*#/ || /^\s*$/;
        eval {
            $self->process_rule($_, \%instances) or log("warning", "$rule_name: $_");
        };
        if ($@) {
            chomp(my $err_msg = $@);
            log("err", "$rule_name: $err_msg");
            return;
        }
    }

    log("warning", "$rule_name ignoring: " . join(",", @rules[$i .. $#rules]))
        if $i < @rules;
    return \%instances;
}

sub new_instance {
    my ($instances, $name) = @_;
    my $prev_instance = $instances->{".CURRENT INSTANCE."};
    $instances->{".CURRENT INSTANCE."} = $name;
    if (exists $instances->{$name}) {
        return;
    } else {
        $instances->{$name} = [ @{$instances->{DEFAULT}} ];
    }
}

sub get_current_results {
    my $ref_instances = shift;
    my $instance_name = $ref_instances->{".CURRENT INSTANCE."};
    my $results = $ref_instances->{$instance_name};
    return defined $results ? $results : [];
}

sub process_rule {
    my ($self, $rule, $ref_instances) = @_;
    local $_ = $rule;

    my $ref_result = get_current_results($ref_instances);

    # system ...   - run, abort file if non-zero exit code.
    /^system\s+(.*)/ and do {
        my $command = $1;
        log("debug", $rule);
        my $i = system $command;
        if ($i) {
            die "$command failed ($i)\n";
        } else {
            return 1;
        }
    };

    /^instance\s+(\S+)/ and do {
        my $instance_name = $1;
        new_instance($ref_instances, $instance_name);
        return 1;
    };

    /^include\s+(\S+)/ and do {
        push @$ref_result, gem_read_raw_file($1);
        return 1;
    };
    /^include_allmatching\s+(\S+)/ and do {
        my $glob = get_rel_glob($1);
        my @files = glob($glob);
        log("warning", "no files match $glob") unless @files;
        for my $file (@files) {
            push @$ref_result, gem_read_raw_file($file);
        }
        return 1;
    };
    /^includefor\s+(\S+)\s+(\S+)/ and do {
        my ($range, $filename) = ($1, $2);
        my @text = gem_read_raw_file($filename);
        for my $node (expand_range($range)) {
            for my $line (@text) {
                my $new = $line;
                $new =~ s/\{\}/$node/g;
                push @$ref_result, $new;
            }
        }
        return 1;
    };
    /^includegz\s+(\S+)/ and do {
        push @$ref_result, gem_read_gzip_raw_file($1);
        return 1;
    };
    /^truncate$/ and do {
        @$ref_result = ();
        return 1;
    };
    /^append\s+(.*)/ and do {
        push @$ref_result, $1;
        return 1;
    };
    /^appendfor\s+(\S+)\s+(.*)/ and do {
        my ($range, $rest) = ($1, $2);
        foreach my $node (expand_range($range)) {
            my $line = $rest;
            $line =~ s/\{\}/$node/g;
            push @$ref_result, $line;
        }
        return 1;
    };
    /^deleterange\s+(\S+)/ and do {
	my ($range) = ($1);
        foreach my $node (expand_range($range)) {
                @$ref_result = grep { $_ !~ /\b$node\b/ } @$ref_result;
        }
        return 1;
    };
    /^deleteregex\s+(.*)/ and do {
	my ($regex) = ($1);
        @$ref_result = grep { $_ !~ /$regex/ } @$ref_result;
        return 1;
    };
    /^appendunique\s+(.*)/ and do {
        my %seen = map { $_ => 1 }  @$ref_result;
        push @$ref_result, $1 unless ($seen{$1});
        return 1;
    };
    /^dedupe$/ and do {
        my %seen;
        @$ref_result = grep( ! ( $seen{$_}++), @$ref_result);
        return 1;
    };
    /^replace\s+(\S+)\s+(.*)/ and do {
        my ($replace_me, $with_this) = ($1, $2);
        @$ref_result = map { s/$replace_me/$with_this/g; $_ } @$ref_result;
        return 1;
    };
    /^replace\s+(\S+)\s*$/ and do {
        my ($replace_me, $with_this) = ($1, "");
        @$ref_result = map { s/$replace_me/$with_this/g; $_ } @$ref_result;
        return 1;
    };
    /^replacere\s+(\S+)\s+(.*)/ and do {
        my ($replace_me, $with_this) = ($1, $2);
        my $code = "\@\$ref_result = map { s/$replace_me/$with_this/g; \$_ } \@\$ref_result;";
        eval "$code";  die "ERROR in $code: $@\n" if ($@);
        return 1;
    };
    /^expand_vars$/ and do {
        foreach (@$ref_result) {
		$_ = expand_vars($_);
	}
	return 1;
    };
    /^etchosthack\s+(\S+)/ and do {
        my $lookup = $1;
        my ($etchosts) = (grep(/\b$lookup\b/,split(/\n/, read_file("/etc/hosts"))));
        unless ($etchosts) { 
            log("debug", "could not find $lookup in /etc/hosts");
            return 1;
        }
        $etchosts =~ s/^\s+//;
        ($etchosts) = split(/\s/,$etchosts);
        @$ref_result = map { s/$etchosts,/$etchosts,$lookup,/g; $_ } @$ref_result;
        return 1;
    };


    return 0;
}

1;
