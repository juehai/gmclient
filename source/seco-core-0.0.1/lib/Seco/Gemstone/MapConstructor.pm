package Seco::Gemstone::MapConstructor;

use strict;
use Config;
use Seco::Gemstone::Utils qw/gem_read_raw_file/;
use base qw/Seco::Gemstone::Constructor/;
use fields qw/delim key sort_field sort_numerically map added_map/;
use Seco::Gemstone::Logger qw/log/;

sub new {
    my ($self, %args) = @_;
    $self = fields::new($self) unless ref $self;
    $self->SUPER::new;
    $self->{delim} = $args{delim} || '\s+';
    $self->{sort_field} = $args{sort_field} || -1; # dont sort by default
    $self->{key} = $args{key} || 0;
    $self->{sort_numerically} = $args{sort_numerically} || 0;
    return $self;
}

sub get_base_file {
    my ($self, $rule_name) = @_;
    return gem_read_raw_file($rule_name);
}

sub construct {
    my Seco::Gemstone::MapConstructor $self = shift;
    my ($rule_name, @rules) = @_;
    my (%map, %added_map);
    my %instances = ('DEFAULT' => [], '.CURRENT INSTANCE.' => 'DEFAULT');
    my @file = $self->get_base_file($rule_name);
    my ($delim, $key) = ($self->{delim}, $self->{key});
    for (@file) {
        next if /^\s*#/ || /^\s*$/;
        my @fields = split($delim, $_);
        $map{$fields[$key]} = $_;
    }
    $self->{map} = \%map;
    $self->{added_map} = \%added_map;
    my $i = 0;
    for (@rules) {
        $i++;                   # to warn about 'eof' and ignoring rules
        s/\s+$//;
        last if /^eof$/;
        $self->process_rule($_, \%instances) or
            log("warning", "$rule_name ($_)");
    }
    log("warning", "$rule_name ignoring: ", join(",", @rules[$i .. $#rules]))
        if $i < @rules;

    return \%instances if $self->{sort_field} < 0;

    while (my ($instance, $val) = each(%instances)) {
        next if $instance =~ /^\./;
        $instances{$instance} = $self->sort_result($self->uniq($val, $self->get_additional_entries));
    }
    return \%instances;
}

sub uniq {
    my $self = shift;
    my ($val1, $val2) = @_;
    my ($delim, $sort_field) = ($self->{delim}, $self->{sort_field});
    my %seen;
    my @result;
    for (@$val1, @$val2) {
        my @fields = split $delim;
        my $key = $fields[$sort_field];
        push @result, $_ unless $seen{$key}++;
    }
    return \@result;
}

sub get_additional_entries {
    my Seco::Gemstone::MapConstructor $self = shift;
    return;
}

sub sort_result {
    my Seco::Gemstone::MapConstructor $self = shift;
    my $values = shift;
    my ($delim, $sort_field, $num_sort) = ($self->{delim}, $self->{sort_field},
        $self->{sort_numerically});
    my $sort_code = $num_sort ?
      sub { $a->[0] <=> $b->[0] } :
        sub { $a->[0] cmp $b->[0] };

    my $maxint = ((1<<(8 * $Config{intsize} - 2))-1)*2 + 1;
    local @_;
    my @sorted = map { $_->[1] }
        sort $sort_code
        map { @_ = split($delim, $_); my $val = $_[$sort_field];
            $val = $maxint unless defined $val; [$val, $_] }
        @$values;

    return \@sorted;
}

sub add {
    my Seco::Gemstone::MapConstructor $self = shift;
    my ($ref_result, $what) = @_;

    my $map = $self->{map};
    my $added_map = $self->{added_map};

    for my $key (split '\s*,\s*', $what) {
        unless (exists $map->{$key}) {
            log("warning", "$what does not exist.");
            next;
        }
        unless ($added_map->{$key}) {
            push @$ref_result, $map->{$key};
            $added_map->{$key} = 1;
        }
    }
    return 1;
};

sub process_rule {
    my Seco::Gemstone::MapConstructor $self = shift;
    my ($rule, $ref_instances) = @_;
    my $cur_instance = $ref_instances->{".CURRENT INSTANCE."};
    my $ref_result = $ref_instances->{$cur_instance};
    if ($rule =~ /^truncate\b/) {
        $self->{added_map} = {};
    }

    return 1 if $self->SUPER::process_rule($rule, $ref_instances);
    local $_ = $rule;

    my $map = $self->{map};
    my $added_map = $self->{added_map};

    /^add\s+(.*)/ and do {
        return $self->add($ref_result, $1);
    };

    /^sort\b/ and do {
        return 1;
    };
    return 0;
}

1;
