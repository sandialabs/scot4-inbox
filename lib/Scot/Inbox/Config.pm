package Scot::Inbox::Config;

require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(build_config);

use strict;
use warnings;
use experimental 'signatures';
use Data::Dumper::Concise;
use Mojo::File qw(path curfile);
use Mojo::Util qw(decode);

# ASSUMES that ENV VARs below are set
# S4INBOX_IMAP_SERVERNAME    ... the hostname of the IMAP server
# S4INBOX_IMAP_PORT          ... the port that the IMAP server listens to
# S4INBOX_IMAP_INBOX         ... the name of the inbox, typically "INBOX"
# S4INBOX_IMAP_USERNAME      ... the username of the inbox owner
# S4INBOX_IMAP_SSL_VERIFY    ... 0 to disable SSL verification, 1 to require it.
# S4INBOX_IMAP_PEEK          ... 0 marks msgs read, 1 leaves them unread
# S4INBOX_GRAPH_LOGIN_URL    ... the url of to log into ms graph with
# S4INBOX_GRAPH_GRAPH_URL    ... the graph url itself
# S4INBOX_GRAPH_SCOPE        ... the graph's scope
# S4INBOX_GRAPH_TENET_ID     ... the tenet id
# S4INBOX_GRAPH_CLIENT_ID    ... the client id
# S4INBOX_GRAPH_CLIENT_SECRET .. the password 
# S4INBOX_GRAPH_USERADDRESS  ... the mailbox address
# S4INBOX_PERMITTED_SENDERS  ... comma separated string listing permitted senders
# S4INBOX_LOG_LEVEL          ... TRACE, DEBUG, INFO, WARN, ERROR
# S4INBOX_LOG_FILE           ... file to append logs to
# S4INBOX_SCOT_API_INSECURE_SSL ... 0 disables SSL verification, 1 to require it.
# S4INBOX_SCOT_API_URI_ROOT     ... the prefix for api uri, https://s4.sandia.gov/api/v1
# S4INBOX_MSV_FILTER_DEFINITIONS... the filename holding the MSV filter definitions
# S4INBOX_MSV_DBM_FILE          ... the filename of the dbm file for msv deduplication
# S4INBOX_SCOT_INPUT_QUEUE      ... alertgroup, event, or dispatch
# S4INBOX_MAIL_CLIENT_CLASS     ... Scot::Inbox::Imap or Scot::Inbox::MSGraph
# S4INBOX_TEST_MODE             ... read inbox regardless of "unread" state and do not change read flags
#
# SECRETS
# S4INBOX_IMAP_PASSWORD      ... the users password
# S4INBOX_GRAPH_CLIENT_SECRET .. the password 
# S4INBOX_SCOT_API_KEY          ... the api key for the scot api server

sub build_config () {

    my $mboxconf;
    my @psenders    = split(';', $ENV{S4INBOX_PERMITTED_SENDERS});
    if ($ENV{S4INBOX_MAIL_CLIENT_CLASS} eq "Scot::Inbox::Imap") {
        $mboxconf   = {
            hostname    => $ENV{S4INBOX_IMAP_SERVERNAME},
            port        => $ENV{S4INBOX_IMAP_PORT},
            mailbox     => $ENV{S4INBOX_IMAP_INBOX} // 'INBOX',
            user        => $ENV{S4INBOX_IMAP_USERNAME},
            pass        => $ENV{S4INBOX_IMAP_PASSWORD},
            ssl         => [ 'SSL_verify_mode', $ENV{S4INBOX_IMAP_SSL_VERIFY} ],
            uid         => 1,
            ignore_size_errors => 1,
            peek        => $ENV{S4INBOX_IMAP_PEEK},
            permitted_senders   => \@psenders,
        };
    }
    else {
        $mboxconf   = {
            loginurl    => $ENV{S4INBOX_GRAPH_LOGIN_URL},
            graphurl    => $ENV{S4INBOX_GRAPH_GRAPH_URL},
            scot        => $ENV{S4INBOX_GRAPH_SCOPE},
            tenet_id    => $ENV{S4INBOX_GRAPH_TENENT_ID},
            client_id   => $ENV{S4INBOX_GRAPH_CLIENT_ID},
            client_secret   => $ENV{S4INBOX_GRAPH_CLIENT_SECRET},
            useraddress   => $ENV{S4INBOX_GRAPH_USERADDRESS},
            reread      => 0,
            bydate      => 0,
            permitted_senders   => \@psenders,
        };
    }
    if (defined $ENV{S4INBOX_TEST_MODE}) {
        $mboxconf->{test_mode}    = $ENV{S4INBOX_TEST_MODE};
    }


    # get MSV filter definitions if they exist
    my $defs    = (defined $ENV{S4INBOX_MSV_FILTER_DEFINITIONS}) 
                    ?  $ENV{S4INBOX_MSV_FILTER_DEFINITIONS}
                    : '/opt/scot4-inbox/etc/msv.defs';
    my $msv_filters = load_filters($defs);

    my $config  = {
        log         => {
            name    => 'Inbox',
            config  => qq{
log4perl.category.Inbox = $ENV{S4INBOX_LOG_LEVEL}, InboxLog
log4perl.appender.InboxLog = Log::Log4perl::Appender::File
log4perl.appender.InboxLog.mode = append
log4perl.appender.InboxLog.filename = $ENV{S4INBOX_LOG_FILE}
log4perl.appender.InboxLog.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.InboxLog.layout.ConversionPattern = %d %7p [%P] %15F{1}: %4L %m%n
            },
        },
        scotapi => {
            insecure    => $ENV{S4INBOX_SCOT_API_INSECURE_SSL},
            api_key     => $ENV{S4INBOX_SCOT_API_KEY},
            uri_root    => $ENV{S4INBOX_SCOT_API_URI_ROOT},
        },
        msv_filters     => $msv_filters,
        msv_msg_id_dbm  => $ENV{S4INBOX_MSV_DBM_FILE},
        scot_queue      => $ENV{S4INBOX_SCOT_INPUT_QUEUE},
        class           => $ENV{S4INBOX_MAIL_CLIENT_CLASS},
        mboxconfig      => $mboxconf,
        addsplunksigs   => $ENV{S4INBOX_ADD_SPLUNK_SIGS}, # for disconnected nets
    };
    return $config;
}

sub load_filters ($file) {
    if (! -e $file) {
        warn "MSV Filter definition file $file does not exist! assuming no msv function";
        return {};
    }
    my $contents    = decode('UTF-8', path($file)->slurp);
    my $hash        = eval 'package Mojolicious::Plugin::Config::Sandbox; '.
                           'no warnings; '.
                           'use Mojo::Base -strict; '.
                           "$contents";

    die qq|Can't load filter defs from $file: $@| if $@;
    die qq|Defs file $file did not return hash ref| if (!ref($hash) eq 'HASH');
    return $hash;
}
1;
