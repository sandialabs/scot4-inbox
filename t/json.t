#!/opt/perl/bin/perl
#
use JSON::PP;
use Hash::Ordered;
use Data::Dumper::Concise;
use List::MoreUtils qw(each_array);

my @columns = ( 'first', 'second', 'beta' );
my @values  = ( 1, 2, 3 );

my $oh  = Hash::Ordered->new();
my $it  = each_array(@columns, @values);

while (my ($c,$v) = $it->() ) {
    $oh->push($c => $v);
}

print Dumper($oh);

my $alertgroup = {
    owner   => 'scot-alerts',
    tlp     => 'unset',
    view_count  => 0,
    message_id  => '12123123123123',
    subject     => 'foobar',
    tags        => ['tag1'],
    sources     => ['source1'],
    alerts      => $oh,
};

print "Plain JSON encoding:\n";
print encode_json([$alertgroup]), "\n";
print "\n";


