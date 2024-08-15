#!/opt/perl/bin/perl

use Mail::IMAPClient;

my $c = Mail::IMAPClient->new(
    'Server',
    'mail.sandia.gov',
    'Port',
    993,
    'User',
    'scot-alerts',
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


my $s = $c->message_string('4638781');
print "$s\n";
