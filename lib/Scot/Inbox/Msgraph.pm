package Scot::Email::MSGraph;

use lib '../../../lib';
use strict;
use warnings;

use Data::Dumper::Concise;
use Encode 'decode';
use Mojo::UserAgent;
use Email::MIME;
use Scot::Inbox::Msgraph::Cursor;

use Mojo::Base -base, -signatures;

# required to be passed in
has 'log';
has 'config';

has loginurl      => sub ($self) { $self->config->{loginurl}; };
has graphurl      => sub ($self) { $self->config->{graphurl}; };
has scope         => sub ($self) { $self->config->{scope}; };
has tenet_id      => sub ($self) { $self->config->{tenet_id}; };
has client_id     => sub ($self) { $self->config->{client_id}; };
has client_secret => sub ($self) { $self->config->{client_secret}; };
has useraddress   => sub ($self) { $self->config->{useraddress}; };
has reread        => sub ($self) { $self->config->{reread}; };
has bydate        => sub ($self) { $self->config->{bydate}; };
has ua            => sub ($self) { return Mojo::UserAgent->new; };
has permitted_senders => sub ($self) { $self->config->{permitted_senders} };

sub get_access_token {
    my ($self)  = @_;
    my $log     = $self->env->log;

    my $url     = join('',
        $self->loginurl,
        '/', $self->tenet_id,
        '/oauth2/v2.0/token'
    );

    $log->debug("Authenticating via $url");

    my $form    = {
        client_id       => $self->client_id,
        client_secret   => $self->client_secret,
        scope           => $self->scope,
        grant_type      => 'client_credentials',
    };

    $log->trace("Sending form data ", {filter =>\&Dumper, value => $form});

    my $ua = $self->ua;
    my $tx = $ua->post($url => form => $form);
    my $json    = $tx->result->json;
    my $token   = $json->{access_token};
    $log->trace("Result json: ",{filter=>\&Dumper, value=>$json});
    return $token;
}

sub get_mail {
    my ($self, $start, $end)  = @_;
    my $log     = $self->env->log;
    my $filter  = '&$filter=';

    if ( $self->bydate ) {
        my $encoded = "received>=$start AND received<=$end";
        $filter .= $encoded;
    }
    else {
        $filter .= 'isRead+ne+true';
    }

    my $url     = join('',
        $self->graphurl,
       '/', $self->useraddress,
       '/messages',
       '?select=sender,subject,isRead',
       $filter,
       '&$top=50',
    );
    my $auth        = $self->build_auth_token;
    my @mids        = ();
    my $moremsgs    = 1;

    while ($moremsgs) {
        $log->debug("Retrieving set of messages via $url");
        my $tx       = $self->ua->get($url => $auth);
        my $json     = $tx->result->json;
        my $nextlink = $json->{'@odata.nextLink'};
        my $messages = $json->{value};
        # add the ids of messages to the message set
        $log->debug("adding ".scalar(@$messages)." to mail id stack");
        push @mids, map {$_->{id}} @$messages;
        if (defined $nextlink) {
            $log->debug("More Messages available at $nextlink");
            $url = $nextlink;
        }
        else {
            $log->debug("no more messages");
            $moremsgs = 0;
        }
    }

    $log->trace("Creating Cursor with ids = ", join(',',@mids));
    
    my $cursor  = Scot::Email::MSGraph::Cursor->new(
        ids     => \@mids,
        msgraph => $self,
        env     => $self->env,
    );
}

sub mark_message_read {
    my ($self, $msgid, $auth) = @_;

    my $url = join('',
        $self->graphurl,
        '/', $self->useraddress,
        '/messages',
        '/', $msgid
    );
    my $update = {isRead => 'TRUE' };
    $auth->{'Content-Type'} = "application/json";
    $self->env->log->debug("mark_read_url  = ",{filter =>\&Dumper, value => $url});
    $self->env->log->debug("mark_read_json = ",{filter =>\&Dumper, value => $auth});
    my $tx      = $self->ua->patch($url => $auth => json => $update);
    my $result  = $tx->result;

    if ($result->is_error) {
        $self->env->log->error("ERROR updating isRead status!");
        my $json    = $result->json;
        $self->env->log->error({filter => \&Dumper, value => $json});
        return;
    }

    $self->env->log->debug("$msgid isRead set to 1");
    return;
}

sub build_message_id_list {
    my $self        = shift;
    my $messages    = shift;
    my @mids        = ();
    my $log         = $self->env->log;

    MSG:
    foreach my $m (@$messages) {
        my $read    = $m->{isRead};
        if ($read && ! $self->reread) {
            $log->debug("Message $m->{id} marked as read, skipping...");
            next MSG;
        }
        $log->debug("Adding $m->{id} to the message stack");
        push @mids, $m->{id};
    }
    return wantarray ? @mids : \@mids;
}

sub build_auth_token {
    my $self    = shift;
    my $token   = $self->get_access_token;
    my $bearer  = "Bearer $token";
    my $auth    = {Authorization => $bearer};
    return $auth;
}

sub get_message {
    my $self    = shift;
    my $id      = shift;
    my $log     = $self->env->log;
    my $url     = join('',
        $self->graphurl,
        '/', $self->useraddress,
        '/messages/',
        $id
    );

    $log->debug("Retrieving Message $id using $url");
    my $auth    = $self->build_auth_token;
    my $tx      = $self->ua->get($url => $auth);
    my $message = $tx->result->json;
    my $from    = $self->get_from($message);

    if ( ! $self->from_permitted_sender($from)) {
        $log->warn("Message from $from who is not on permitted sender list");
        return { error => 'nonpermitted sender' };
    }
    
    my $attachments = ($message->{hasAttachments}) ? $self->get_attachments($id) 
                                                   : [];

    my $scotmsg    = {
        graph_id        => $id,
        source          => 'msgraph',
        subject         => $self->get_subject($message),
        from            => $from,
        to              => $self->get_to($message),
        when            => $self->get_when($message),
        message_id      => $self->get_message_id($message),
        body            => $self->get_html_body($message),
        plain           => $self->get_plain_body($url, $auth),
        attachments     => $attachments,
    };
    $log->debug("Build ScotMSG ", {filter=>\&Dumper, value=>$scotmsg});
    $self->mark_message_read($id, $auth);
    return $scotmsg;
}

sub get_html_body {
    my ($self, $message) = @_;
    my $body    = $message->{body};

    if ( $body->{contentType} eq "html" ) {
        return $body->{content};
    }
    $self->env->log->warn("No HTML body found!");
    return '';
}

sub get_plain_body {
    my ($self, $url, $auth) = @_;
    my $log = $self->env->log;
    $log->debug("attempting to get plain body");
    $auth->{Prefer} = 'outlook.body-content-type="text"';
    my $tx  = $self->ua->get($url => $auth);
    my $result  = $tx->result->json;
    $log->debug("Got: ",{filter =>\&Dumper, value => $result});
    return $result->{body}->{content};
}

sub get_attachments {
    my ($self, $id)     = @_;
    my $log             = $self->env->log;
    my $url = join('',
        $self->graphurl,
        '/messages/',$id,'/attachments');
    my $auth    = $self->build_auth_token;

    $log->debug("Getting Attachment List with : $url");
    # TODO: see how images in email html are handled 
    # and mimi Imap.pm inlining of images

    my $tx      = $self->ua->get($url => $auth);
    my $json    = $tx->result->json;
    my @attachments     = ();

    foreach my $attachment (@{$json->{value}}) {
        my $aid     = $attachment->{id};
        my $size    = $attachment->{size};
        my $dlurl   = $url . "/$aid/".'$value';
        
        $log->debug("Downloading attachment with : $dlurl");

        my $tx      = $self->ua->get($dlurl => $auth);
        my $content = $tx->result->content;

        push @attachments, {
            filename    => $attachment->{name},
            mime_type   => $attachment->{contentType},
            content     => $content,
        };
    }
    $log->trace("Found attachments: ", {filter=>\&Dumper, value=>\@attachments});
    return wantarray ? @attachments : \@attachments;
}

sub get_mime {
    my ($self, $url, $auth) = @_;

    $url .= '/$value';  # will retrieve the mime version of the email
    $auth = $self->build_auth_token if (! defined $auth);

    my $log = $self->env->log;
    $log->debug("Getting MIME message with $url");

    my $tx      = $self->ua->get($url => $auth);
    my $mime    = $tx->result->body;

    $log->debug("result:  ", {filter => \&Dumper, value => $tx->result});

    # hack, email::mime can parse the MS Graph output
    # but Courriel can't, go figure.  So I parse and "deparse"
    # using Email::Mime and then Courriel does parse it without error
    my $parsed = Email::MIME->new($mime);
    my $mm     = $parsed->as_string;


    $log->debug("Results: \n$mm");

    return $mm;
}

sub get_subject {
    my ($self, $msg) = @_;
    return $msg->{subject};
}

sub get_from {
    my ($self, $msg) = @_;
    return $msg->{from}->{emailAddress}->{address};
}

sub get_to {
    my ($self, $msg) = @_;
    return join(', ',
        map { $_->{emailAddress}->{address} } @{$msg->{toReceipients}}
    );
}

sub get_when {
    my ($self, $msg) = @_;
    my $tstring      = $msg->{receivedDateTime};
    my ($ymd,$hmsz)  = split(/T/, $tstring, 2);
    my ($y, $m, $d)  = split(/-/, $ymd);
    my ($h, $min, $sz)= split(/:/, $hmsz);
    my $s            = substr($sz, 0, -1);
    my $dt          = DateTime->new(
        year     => $y,
        month    => $m,
        day      => $d,
        hour     => $h,
        minute   => $min,
        second   => $s,
        time_zone=> 'UTC',
    );
    return $dt->epoch;
}

sub get_message_id {
    my ($self, $msg) = @_;
    return $msg->{internetMessageId};
}

sub get_message_string {
    my ($self, $msg) = @_;
    return $msg->{body}->{content};
}


sub from_permitted_sender {
    my $self    = shift;
    my $from    = shift;
    my @oksenders   = @{$self->permitted_senders};
    my $log     = $self->env->log;

    # each permitted sender can be a regex, 
    # a '*' match all wildcard, or and explicit
    # string match

    foreach my $oksender (@oksenders) {

        if ( $self->regex_match($oksender, $from) 
             or $self->wildcard_match($oksender)
             or $self->explicit_match($oksender, $from)
           ) {
                return 1;
        }
    }
}

sub regex_match {
    my $self    = shift;
    my $ok      = shift;
    my $from    = shift;

    if ( ref($ok) ) {
        return $from =~ /$ok/;
    }
    return undef;
}

sub wildcard_match {
    my $self    = shift;
    my $ok      = shift;
    return $ok eq '*';
}

sub explicit_match {
    my $self    = shift;
    my $ok      = shift;
    my $from    = shift;
    return $ok eq $from;
}



1;

