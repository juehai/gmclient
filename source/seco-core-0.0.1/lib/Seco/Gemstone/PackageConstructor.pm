package Seco::Gemstone::PackageConstructor;

use strict;
use IO::Socket::INET;
use Sys::Hostname;
use base qw/Seco::Gemstone::Constructor/;
use fields;
use Seco::Gemstone::Logger qw/log/;

sub new {
    my ($self) = @_;
    $self = fields::new($self) unless ref $self;
    $self->SUPER::new;
    return $self;
}

sub construct {
    my Seco::Gemstone::PackageConstructor $self = shift;
    my $instances = $self->SUPER::construct(@_);
    my $cur_instance = $instances->{".CURRENT INSTANCE."};
    my $results = $instances->{$cur_instance};

    # automatically add certain packages
    # (for now just the kernel)
    my $kernel_package = kernel_package();
    push @$results, "$kernel_package install" if $kernel_package;
    return $instances;
}

sub kernel_package {
    my $s = IO::Socket::INET->new("boothost:9999");
    my $hostname = hostname();
    my $kernel_package;
    unless ($s) {
        log("err", "can't connect to boothost:9999");
        return;
    }
    print $s "GET /jumpstart/hostconfig.cgi?hostname=$hostname\n\n";
    while (<$s>) {
        next unless /^kernel_package: (.*)/;
        $kernel_package = $1;
	$kernel_package =~ s/2\.6\.9-22\.12\.y1\.35smp/2.6.9-22.12.y1.35-32/;
	my $vmlinuz = $kernel_package;
	my $initrd = $kernel_package;
	$vmlinuz =~ s/^kernel-/vmlinuz-/;
	$initrd =~ s/^kernel-/initrd-/;
	$initrd =~ s/$/.img/;
        log("debug", "AUTOADDING: $kernel_package");
	log("debug", "SYMLINKING: /boot/boot-{kernel,initrd} to $vmlinuz, $initrd");
	system("ln -sfn $vmlinuz /boot/boot-kernel");
	system("ln -sfn $initrd /boot/boot-initrd");
	log("debug", "HACKING: /boot/grub/menu.lst");
        if (-e "/boot/grub/menu.lst") {
            open my $menulst, "</boot/grub/menu.lst";
            my @MENU = <$menulst>;
            close $menulst;
            chomp @MENU;
            my @newmenu = grep { ! /^  initrd/ } @MENU;
            push @newmenu, "  initrd /boot/boot-initrd"
              if -e "/boot/boot-initrd";
            open $menulst, ">/boot/grub/menu.lst.tmp";
            print $menulst (join "\n", @newmenu);
            print $menulst "\n";
            close $menulst;
            rename "/boot/grub/menu.lst.tmp" => "/boot/grub/menu.lst";
        }
    }
    close $s;
    return $kernel_package;
}
1;
