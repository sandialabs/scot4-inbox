#!/opt/perl/bin/perl
#
use feature 'signatures';
sub is_permitted ($from, $cleared) {
    print ("does $from match $cleared?\n");

    return 1 if (regex_match($cleared, $from));
    return 1 if (wildcard_match($cleared));
    return 1 if (loose_match($cleared, $from));
    return 1 if (explicit_match($cleared, $from));

    print ("Failed to match $from to $cleared\n\n");
    return undef;
}

sub regex_match ( $ok, $from) {
    if ( ref($ok) eq 'Regexp' ) {
        print ("checking for regex match\n");
        return $from =~ /$ok/;
    }
    return undef;
}

sub wildcard_match ($ok) {
    print ("checking for wildcard\n");
    return $ok eq '*';
}

sub explicit_match ($ok, $from){
    print ("Explicit match check $ok eq $from\n");
    return $ok eq $from;
}

sub loose_match ($ok, $from) {
    print ("Loose match check $ok eq $from\n");
    return $from =~ /$ok/;
}

my @permitted   = (qw(foo@bar.com boom@bam.gov));
my @from        = (
    'Boom, J Chuck boom@bam.gov',
    'foo@foo.com',
    'Bar, Foo foo@bar.com',
    'bing@bada.com',
);

foreach my $f (@from) {
    print "FROM: $f\n";
    foreach my $p (@permitted) {
        print "P = $p\n";
        if (is_permitted($f, $p)) {
            print "$_ is permitted\n\n";
        }
    }
}
