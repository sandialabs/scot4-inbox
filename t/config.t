#!/opt/perl/bin/perl

use Test::Most;
use Data::Dumper::Concise;
use lib '../lib';
use Scot::Inbox::Config qw(build_config);
use feature qw(say);

my $cfile   = "../etc/inbox.conf";
my $sfile   = "../etc/secrets.conf";
my $test    = 0;
$ENV{'S4INBOX_MSV_FILTER_DEFINITIONS'} =  "../etc/msv.defs";

my $genconf = build_config();
my $expect  = {
};


print Dumper($genconf),"\n";




done_testing();
exit 0;

cmp_deeply($genconf, $expect, "Got expected config");
