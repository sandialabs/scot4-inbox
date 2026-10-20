#!/opt/perl/bin/perl

use Mail::IMAPClient;

my $c = Mail::IMAPClient->new(
    'Server',
    'mail.example.com',
    'Port',
    993,
    'User',
    'scot-alerts-account',
    'Password',
    'changeme',
    'Ssl',
    [
      'SSL_verify_mode',
      0
    ],
    'Uid',
    1,
    'Ignoresizeerrors',
    undef);


my $s = $c->message_string('1');
print "$s\n";
