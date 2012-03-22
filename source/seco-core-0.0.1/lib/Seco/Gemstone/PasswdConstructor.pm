package Seco::Gemstone::PasswdConstructor;

use strict;
use base qw/Seco::Gemstone::MapConstructor/;
use fields qw/defaultshell os_file/;
use Seco::Gemstone::Utils qw/read_file gem_read_raw_file/;
use Seco::Gemstone::Logger qw/log/;

sub new {
    my ($class, %args) = @_;
    my Seco::Gemstone::PasswdConstructor $self = fields::new($class);
    $self->SUPER::new(delim => ':', sort_field => 2, sort_numerically => 1);
    $self->{defaultshell} = '/bin/sh'; # TODO (verify users shells)
    $self->{os_file} = undef;
    return $self;
}

sub get_additional_entries {
    my Seco::Gemstone::PasswdConstructor $self = shift;
    my @os_file;
    if ($self->{os_file}) {
        @os_file = gem_read_raw_file($self->{os_file});
    }
    return \@os_file;
}

sub process_rule {
    my Seco::Gemstone::PasswdConstructor $self = shift;
    my ($rule, $ref_instances) = @_;
    my $cur_instance = $ref_instances->{".CURRENT INSTANCE."};
    my $ref_result = $ref_instances->{$cur_instance};

    return 1 if $self->SUPER::process_rule($rule, $ref_instances);
    local $_ = $rule;
    my $users = $self->{map};

    /^os_file\s+(.*)$/ and do {
        $self->{os_file} = $1;
        return 1;
    };

    /^local_passwd\b/ and do {
        $self->_local_passwd($users, $ref_result);
        return 1;
    };

    /^disable\b/ and do {
        s{disable}{chsh_to /bin/false};
    };

    /^ch(passwd|uid|gid|name|home|sh)_to\b/ and do {
        my $what = $1;
        my (undef, $to, @users) = split;
        for my $user (@users) {
            unless (exists $users->{$user}) {
                log("warning", "$user does not exist");
                next;
            }
            $users->{$user} = _chentry($users->{$user}, $what, $to);
            for my $entry (@$ref_result) {
                next unless $entry =~ /^${user}:/;
                $entry = $users->{$user};
            }
        }
        return 1;
    };

    return;
}

# Start with the local passwd file
sub _local_passwd {
    my Seco::Gemstone::PasswdConstructor $self = shift;
    my ($ref_users, $ref_result) = @_;
    my $passwd_file = $^O eq "freebsd" ? "/etc/master.passwd" :
        "/etc/passwd";
    my $etc_passwd = read_file($passwd_file);
    $self->_update_shells($etc_passwd);
    my $map = $self->{map};
    for my $line (split "\n", $etc_passwd) {
        next if $line =~ /^#/;
        my $user = (split /:/, $line)[0];
        if (exists($map->{$user})) {
            $self->add($ref_result, $user);
        } else {
            $map->{$user} = $line;
            $self->add($ref_result, $user);
            $self->_disable_user($user);
        }
    }
}

# Do something with users thar are no longer in the 
# main passwd file
sub _disable_user {
    my Seco::Gemstone::PasswdConstructor $self = shift;
    my $user = shift;

    my %disabled_users;
    unless (-d "var") {
        mkdir "var" or die "Can't create var subdir\n";
    }
    use SDBM_File; use Fcntl;
    tie %disabled_users, 'SDBM_File', 'var/disabled_users.dbmx', 
        O_RDWR|O_CREAT, 0640;

    unless (exists $disabled_users{$user}) {
        open my $ofh, ">>var/newly_disabled_users.txt";
        print $ofh "$user\n";
        close $ofh;
        $disabled_users{$user} = 1;
    }

    untie %disabled_users;
}



# this updates the yanis shell with the shell currently used by the
# system for this user - maybe we should do this for other fields
sub _update_shells {
    my Seco::Gemstone::PasswdConstructor $self = shift;
    my $etc_passwd = shift;
    my $map = $self->{map};
    for my $line (split("\n", $etc_passwd)) {
        my @fields = split /:/, $line;
        my ($user, $shell) = ($fields[0], $fields[-1]);
        if ($map->{$user}) {
            my @fields = split /:/, $map->{$user};
            $fields[-1] = $shell;
            $map->{$user} = join(":", @fields);
        }
    }
}
    

# Change a field in an /etc/passwd line
my %what_nr_linux = (passwd => 1, uid => 2, gid => 3, name => 4, 
    home => 5, sh => 6);
my %what_nr_fbsd = (passwd => 1, uid => 2, gid => 3, class => 4, 
    pwexpire => 5, accountexpire => 6, name => 7, home => 8, sh => 9);
my %what_nr = $^O eq "freebsd" ? %what_nr_fbsd : %what_nr_linux ;

sub _chentry {
    my ($entry, $what, $to) = @_;
    my @fields = split /:/, $entry;
    $fields[$what_nr{$what}] = $to;
    return join(":", @fields);
}

1;
