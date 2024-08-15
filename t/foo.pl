use Data::Dumper;
my @s   = ();

$columns = ['one','two','three'];

for (my $i = 0; $i < scalar(@$columns); $i++) {
    push @s, {
        index   => $i,
        name    => $columns->[$i],
    };
}

print Dumper(@s);
