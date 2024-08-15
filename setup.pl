#!/opt/perl/bin/perl
#
use Mojo::Base -strict, -signatures;
use Data::Dumper::Concise;
use JSON;
use Getopt::Long;

my $install_dir = "/opt/scot4-inbox";
my $inbox_user  = "scotinbox";
my $inbox_group = "scotinbox";
my $nocontainer = 0;                    # 0 = in container
my $clean       = 0;

####
#### NON DOCKER/Container install script
#### only use if you wish to install directly on a host
####

GetOptions(
    "instdir=s" => \$install_dir,
    "user=s"    => \$inbox_user,
    "group=s"   => \$inbox_group,
    "nocontainer" => \$nocontainer,
) or die <<EOF;

Usage:

    $0
        [--instdir /path/to/dir]  where to install 
        [--user username]         unix user to own this process
        [--group group]           unix group to own this process
        [--nocontainer]           install to not be run inside container
        [--clean]                 delete contents of instdir prior to install

EOF

if ( $> != 0 ) {
    die "You must execute this script with effective root privileges. try: sudo $0";
}

if ($install_dir eq '/' or $install_dir eq ' ' or $install_dir eq '') {
    die 'Can not install on / or blank install dir!';
}

my $prep = << "EOF";
if grep --quiet -c $inbox_group: /etc/group; then
    echo "$inbox_group already exists, reusing..."
else
    groupadd $inbox_group
fi

if grep --quiet -c $inbox_user: /etc/passwd; then
    echo "$inbox_user already exists, reusing..."
else 
    useradd -c "Scot Inbox User" -g $inbox_group -d $install_dir -M -s /bin/bash $inbox_user
fi

EOF

system($prep);

if (-d $install_dir) {
    say "$install_dir exists...";
    if ($clean) {
        say "...you asked to clean it...";
        system("rm -rf $install_dir/*");
        system("mkdir -p $install_dir");
    }
}
else {
    system("mkdir -p $install_dir");
}


my $copyscript = << "EOF";
    tar --exclude-vcs -cf - . | (cd $install_dir; tar xf -)
EOF
system($copyscript);



