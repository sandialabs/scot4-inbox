#!/opt/perl/bin/perl

use Test::Most;
use Data::Dumper::Concise;
use lib '../lib';
use Scot::Inbox::Config qw(build_config);
use Scot::Inbox::Log qw(start_logging);
use feature qw(say);

my $cfile   = "../etc/inbox.conf";
my $sfile   = "../etc/secrets.conf";
my $test    = 0;

my $conf = build_config($cfile, $sfile, $test);
my $logconf = $conf->{global}->{log};

print Dumper($logconf),"\n";

my $log = start_logging($logconf);

is (ref($log), "Log::Log4perl::Logger", "got a logger object");
print Dumper($log);
$log->warn("TEST");

done_testing();
exit 0;

