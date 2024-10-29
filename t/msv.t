#!/opt/perl/bin/perl

use Test::Most;
use Data::Dumper::Concise;
use lib '../lib';
use Scot::Inbox::Processor; 
use Scot::Inbox::Config;
use Scot::Inbox::Log;
use Storable qw(dclone);
use feature qw(say);

$ENV{S4INBOX_IMAP_SERVERNAME} = "mail.sandia.gov";
$ENV{S4INBOX_IMAP_PORT}       = 993;
$ENV{S4INBOX_IMAP_INBOX}      = 'INBOX';
$ENV{S4INBOX_IMAP_USERNAME}   = 'scot-alerts';
$ENV{S4INBOX_IMAP_PASSWORD}   = '';
$ENV{S4INBOX_SSL_VERIFY}      = 1;
$ENV{S4INBOX_IMAP_PEEK}       = 1;
$ENV{S4INBOX_PERMITTED_SENDERS} = '*,tbruner@sandia.gov';
$ENV{S4INBOX_MSV_FILTER_DEFINITIONS}  = '../etc/msv.defs';
$ENV{S4INBOX_LOG_LEVEL}       = 'TRACE';
$ENV{S4INBOX_LOG_FILE}        = './test.log';
$ENV{S4INBOX_SCOTAPI_INSECURE_SSL}  = 0;
$ENV{S4INBOX_API_KEY}         = '';
$ENV{S4INBOX_API_URI_ROOT}    = 'https://scot4-qual/api/v1';
$ENV{S4INBOX_MSV_DBM_FILE}    = '../var/msgids.dbm';
$ENV{S4INBOX_MAIL_CLIENT_CLASS} = 'Scot::Inbox::Imap';
$ENV{S4INBOX_SCOT_INPUT_QUEUE} = 'alertgroup';

my $config  = build_config();
my $log     = start_logging($config->{log});
my $proc    = Scot::Inbox::Processor->new(
    config  => $config,
    log     => $log,
);

my $json    = {
    message_id  => '<1234567@098765>',
    data        => [
        { 
            domain  => 'ct-salsa.ca.sandia.gov',
            stuff   => 'goes here',
        },
        {
            domain  => 'www.google.com',
            stuff   => 'dies here',
        },
    ],
};
my $json2 = dclone($json);

$proc->filter_msv($json);

say Dumper($json);

$proc->filter_msv($json2);

say Dumper($json2);


