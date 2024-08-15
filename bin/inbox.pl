#!/opt/perl/bin/perl

use lib '/opt/scot4-inbox/lib';
use lib '../lib';
use Mojo::Base -strict, -signatures;
use Scot::Inbox::Processor;
use Getopt::Long qw(GetOptions);

my $pidfile = "/tmp/scot.inbox.pid";

if ( -s $pidfile ) {
    die "$pidfile exists. Kill running $0 and delete $pidfile to continue";
}

open(my $fh, ">", $pidfile) or die "Unable to write to $pidfile!";
print $fh "$$";
close($fh);

END {
    system("rm -f $pidfile");
}

# option defaults
my $configfile  = "../etc/inbox.conf";
my $test        = 0;
my $secrets     = "../etc/secrets.conf";
my $msv         = 1;
my $nomsv       = 0;
my $msvlog      = "/opt/scot4-inbox/var/log/msv.log";

my $default_note    = <<EOF;
        note: default config  is $configfile
              default secrets is $secrets
              default msvlog  is $msvlog

EOF

GetOptions(
    'config=s'  => \$configfile,
    'test'      => \$test,
    'secrets=s' => \$secrets,
    'msv'       => \$nomsv,
    'msvlog'    => \$msvlog,
) or die <<EOF;

Invalid Option!
    
    usage: $0
        [--test]                          overwrites peeking to true
        [--config=/path/to/inbox.conf]    use this file as the configuration file
        [--secrets=/path/to/secrets.conf] use this file for secret storage
        [--msv]                           do not filter msv data
        [--msvlog=/path/to/log]           where to log msv hits

        $default_note
EOF

if ($nomsv) {
    $msv = 0;
}

my $opts    = {
    configfile  => $configfile,
    test        => $test,
    secrets     => $secrets,
    msv         => $msv,
    msvlog      => $msvlog,
};

Scot::Inbox::Processor->new($opts)->run();



