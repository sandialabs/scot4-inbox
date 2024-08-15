package Scot::Inbox::Imap;

use lib '../../../lib';
use strict;
use warnings;

use Courriel;
use Data::Dumper::Concise;
use Encode 'decode';
use MIME::Parser;
use Try::Tiny::Retry qw/:all/;
use Try::Tiny;
use Mail::IMAPClient;
use Readonly;
use HTML::Element;
use HTML::TreeBuilder;
use URI;
Readonly my $MSG_ID_FMT => qr/\A\d+\z/;
use Scot::Inbox::Imap::Cursor;

use Mojo::Base -base, -signatures;

# required to be passed in via new
has 'log';
has 'config';

# construct Mail::IMAPClient using config 
has 'client'    => sub ($self) {
    return $self->connect;
};

sub connect ($self) {
    my $config  = $self->config;
    my @options = (
        Server              => $config->{hostname},
        Port                => $config->{port},
        User                => $config->{user},
        Password            => $config->{pass},
        Ssl                 => $config->{ssl},
        Uid                 => $config->{uid},
        Ignoresizeerrors    => $config->{ignore_size_errors},
    );


    # note this will dump a password into the log 
    # so only enable if you really need to verify all options
    #$self->log->trace("Initializing IMAP client w/ options: ", 
    #            {filter =>\&Dumper, value => \@options});
    
    my $client = try {
        Mail::IMAPClient->new(@options);
    }
    catch {
        $self->log->error("Failed to connect to IMAP server!");
        $self->log->error($_);
        # undef $client;
    };

    if (defined $client and ref($client) eq "Mail::IMAPClient") {
        $self->log->debug("Imap connected...");
    }
    else {
        $self->log->logdie("Failed to create Mail::IMAPClient: $@");
    }

    if ( $self->config->{peek} or $self->config->{test_mode} ) {
        $self->log->debug("setting Peek to 1, prevents setting \\Seen flag");
        $client->Peek(1);
    }
    return $client;
};
    
has permitted_senders => sub ($self) { 
    my $ps = $self->config->{permitted_senders};
    $self->log->debug("Permitted senders: ", {filter => \&Dumper, value => $ps});
    if ( defined $ps and scalar(@$ps) > 0 ) {
        return $ps;
    }
    return ['*'];
};

has test_mode   => sub ($self) {
    if (defined $self->config->{test_mode}) {
        return $self->config->{test_mode};
    }
    return undef;
};

has fetch_mode  => sub ($self) { 
    if ($self->test_mode) {
        return 'testmode';
    }
    return 'unseen';
};
has seconds_ago => sub { 60 * 60 * 1 * 1 };

sub since ($self) {
    my $seconds_ago = $self->seconds_ago;
    my $since = time() - $seconds_ago;
    return $since;
}

sub before ($self) {
    my $seconds_in_past = 2 * 365 * 24 * 3600;
    my $before  = time() - $seconds_in_past;
    return $before;
}

sub get_mail ($self) {
    return ( $self->fetch_mode eq 'unseen' ) ? $self->get_unseen_cursor()
                                             : $self->get_since_cursor();
}


sub get_unseen_cursor ($self) {
    my @uids    = $self->get_unseen_mail;
    my $cursor  = Scot::Inbox::Imap::Cursor->new({imap => $self, uids => \@uids});
    return $cursor;
}

sub get_unseen_mail ($self) {
    my $log     = $self->log;
    my $client  = $self->client;
    $log->debug("Retrieving unseen mail");

    my @unseen_uids;
    retry {
        my $mbox = $self->config->{mailbox};
        $log->debug("examining mbox $mbox");
        $client->select($mbox);
        $client->Uid(0);
        @unseen_uids = $client->unseen; 
        $log->debug("Unseen Mail: ",{filter=>\&Dumper, value=>\@unseen_uids});
    }
    on_retry {
        $log->error($client->LastError);
        $log->debug("Retrying connection to imap server...");
        $self->client($self->connect);
    }
    catch {
        $log->error("Failed to get unseen messages: $_");
        die "Failed to get unseen messages\n";
    };

    if ( scalar(@unseen_uids) == 0 ) {
        $log->warn("No unseen messages...");
    }
    else {
        $log->trace(scalar(@unseen_uids)." unread messages found.");
    }
    return wantarray ? @unseen_uids : \@unseen_uids;
}

sub get_since_cursor ($self) {
    my $since   = $self->since();
    # $self->log->debug("Retrieving mail since ".$self->env->get_human_time($since));
    my @uids    = $self->get_mail_since($since);
    my $cursor  = Scot::Email::Imap::Cursor->new({imap => $self, uids => \@uids});
    return $cursor;
}

sub get_before_cursor ($self) {
    my $before  = $self->before();
    my @uids    = $self->get_mail_before($before);
    my $cursor  = Scot::Email::Imap::Cursor->new({imap => $self, uids => \@uids});
    return $cursor;
}

sub get_mail_since ($self, $since) {
    my $log     = $self->log;
    my $client  = $self->client;

    if ( ! defined $since ) {
        $since = $self->since();
    }

    my @uids;
    retry {
        $client->select($self->mailbox);
        foreach my $message_id ($client->since($since)) {
            if ( $message_id =~ $MSG_ID_FMT ) {
                push @uids, $message_id;
            }
        }
    }
    catch {
        $log->logdie("Failed to set messages since $since: $_");
    };
    return wantarray ? @uids :\@uids;
}

sub get_mail_before ($self, $before) {
    if (! defined $before) {
        $before = $self->before;
    }
    my @uids;
    retry {
        $self->client->select($self->mailbox);
        foreach my $message_id ($self->client->before($before)) {
            if ( $message_id =~ $MSG_ID_FMT) {
                push @uids, $message_id;
            }
        }
    }
    catch {
        $self->log->logdie("Failed to get messages before $before: $_");
    };
    return wantarray ? @uids : \@uids;
}

sub get_envelope_from_uid ($self, $uid) {
    my $log     = $self->log;
    my $envelope;

    retry {
        $envelope    = $self->client->get_envelope($uid);
        $log->trace("Envelope is ",{filter=>\&Dumper,value=>$envelope});
    }
    catch {
        $log->error("Error from IMAP: $_");
    };

    $log->trace("Envelope is ",{filter=>\&Dumper,value=>$envelope});

    return $envelope;
}


sub get_message ($self, $uid) {
    my $log     = $self->log;
    my $client  = $self->client;
    return unless $uid;

    my $peek = $self->config->{peek};
    my $mode = $peek ? "Peeking" : "Nonpeeking";
    $log->debug("Getting Message uid=$uid ($mode)");
    $self->client->Peek($peek);

    my $envelope = $self->get_envelope_from_uid($uid);
    my $from     = $self->get_from($envelope);

    if ( ! $self->from_permitted_sender($from))  {
        $log->warn("Message from $from that is not in the permitted senders list");
        return { error => "Sender $from NOT in permitted sender list" };
    }

    my $courriel    = $self->get_courriel_obj($uid);
    my $htmlbody    = $self->get_html_body($courriel);
    my $tree        = $self->build_html_tree($htmlbody);
    my $attachments = $self->handle_attachments($courriel, $tree);
    my $inlinedhtml = $tree->as_HTML();

    my $csub = $courriel->subject();

    my %message = (
        imap_uid    => $uid,
        source      => 'imap',
        subject     => $csub,
        from        => $from,
        to          => $self->get_to($envelope),
        when        => $self->get_when($courriel),
        message_id  => $self->get_message_id($uid),
        body        => $htmlbody,
        plain       => $self->get_plain_body($courriel),
        attachments => $attachments,
    );

    return wantarray ? %message : \%message;
}

sub get_html_body ($self, $courriel) {
    my $part        = $courriel->html_body_part();
    if ( defined $part ) {
        return $part->content;
    }
    $self->log->error("Failed to get HTML body!");
    return;
}

sub get_plain_body ($self, $courriel) {
    my $part        =  $courriel->plain_body_part();
    if ( defined $part ) {
        return $part->content;
    }
    $self->log->error("Failed to get Plain body!");
    return;
}

sub handle_attachments  ($self, $courriel, $tree) {
    $self->log->debug("handling attachments...");
    my %images  = $self->get_images($courriel);
    $self->inline_images($tree, \%images);

    my @remaining   = ();
    foreach my $part ($courriel->parts()) {
        if ($part->is_attachment) {
            $self->log->debug( "... attachment ".$part->filename." found...");
            push @remaining, {
                filename    => $part->filename,
                mime_type   => $part->mime_type,
                multipart   => $part->is_multipart,
                content     => $part->content,
            };
        }
    }
    return wantarray ? @remaining : \@remaining;
}

sub from_permitted_sender ($self, $from) {
    my @oksenders   = @{$self->permitted_senders};

    $self->log->debug("Checking $from against permitted: ",{filter=>\&Dumper, value => @oksenders});

    # each permitted sender can be a regex, 
    # a '*' match all wildcard, or and explicit
    # string match

    foreach my $oksender (@oksenders) {
        if ( $self->is_permitted($from, $oksender)) {
                $self->log->debug("it matched!");
                return 1;
        }
    }
    return undef;
}

sub is_permitted ($self, $from, $cleared) {
    $self->log->debug("does $from match $cleared?");

    return 1 if ($self->regex_match($cleared, $from));
    return 1 if ($self->wildcard_match($cleared));
    return 1 if ($self->loose_match($cleared, $from));
    return 1 if ($self->explicit_match($cleared, $from));

    $self->log->debug("Failed to match $from to $cleared");
    return undef;
}

sub regex_match ($self, $ok, $from) {
    if ( ref($ok) eq 'Regexp' ) {
        $self->log->debug("checking for regex match");
        return $from =~ /$ok/;
    }
    return undef;
}

sub wildcard_match ($self, $ok) {
    $self->log->debug("checking for wildcard");
    return $ok eq '*';
}

sub explicit_match ($self, $ok, $from){
    $self->log->debug("Explicit match check $ok eq $from");
    return $ok eq $from;
}

sub loose_match ($self, $ok, $from) {
    $self->log->debug("Loose match check $ok eq $from");
    return $from =~ /$ok/;
}


sub get_subject ($self, $uid) {
    my $client  = $self->client;
    my $log     = $self->log;

    my $subject = retry {
        $client->subject($uid);
    }
    delay_exp {
        5, 1e6
    }
    catch {
        $log->error("Failed to get subject");
        $log->error($_);
    };
    my $decoded_subject = decode('MIME-Header', $subject);

    $log->debug("Subject was $subject and is now $decoded_subject");

    if ($decoded_subject =~ /FLAGS \(.* completed.$/ ) {
        $decoded_subject =~ s/(.*) FLAGS \(.* completed./$1/;
    }
    $log->debug("Subject finally is $decoded_subject");

    return $decoded_subject;
}

sub get_from ($self, $envelope) {
    my $angle_quoted           = $envelope->from_addresses;
    (my $from = $angle_quoted) =~ s/[<>]//g; # strip <> 
    return $from;
}

sub get_to ($self, $envelope) {
    return join(', ', $envelope->to_addresses);
}

sub get_courriel_obj ($self, $uid){
    my $log         = $self->log;
    my $client      = $self->client;
    $log->debug("attempting to get message string of $uid");
    my $msgstring   = $client->message_string($uid);
    $log->debug("Last Error: ".$client->LastError);
    my $co  = Courriel->parse( text => $msgstring );
    return $co;
}

sub get_when ($self, $courriel) {
    my $dt          = $courriel->datetime();
    my $epoch       = $dt->epoch;
    return $epoch;
}

sub get_message_id ($self, $uid) {
    my $client  = $self->client;
    my $log     = $self->log;

    my $msg_id  = retry {
        $client->get_header($uid, "Message-Id");
    }
    delay_exp {
        5, 1e6
    }
    catch {
        $log->error("failed to get Message-Id header");
    };

    # XXX
    if ($msg_id =~ /FLAGS \(.* completed.$/ ) {
        $msg_id =~ s/(.*) FLAGS \(.* completed.$/$1/;
    }

    return $msg_id;
}

sub mark_uid_unseen ($self, $uid) {
    my $log     = $self->log;
    my $client  = $self->client;
    my @usuid   = ($uid);

    $log->trace("Marking message $uid as Unseen");

    retry {
        $client->unset_flag('\Seen', @usuid);
    }
    catch {
        $log->error("failed to mark $uid as unseen");
    }
}

sub build_html_tree ($self, $body) {
    my $log     = $self->log;

    $log->debug("building html tree");

    if ( ! defined $body ) {
        $log->error("NO BODY TO PARSE!");
        return undef;
    }

    my $tree    = HTML::TreeBuilder->new;
    $tree       ->implicit_tags(1);
    $tree       ->implicit_body_p_tag(1);
    $tree       ->parse_content($body);

    unless ( $tree ) {
        $log->error("Unable to Parse HTML!");
        $log->error("Body = $body");
        return undef;
    }
    return $tree;
}

sub get_images ($self, $courriel) {
    $self->log->debug("Getting images in message...");
    my %images              = ();

    foreach my $part ($courriel->parts) {
        my $mime        = $part->mime_type;
        next unless ($mime =~ /image/);
        my $encoding    = $part->encoding;
        my $content     = $part->content;
        my $filename    = $part->filename;

        $self->log->debug("building image element for $filename");

        $images{$filename}  = $self->build_img_element($mime, $content, $filename);
    }
    return wantarray ? %images :\%images;
}

sub build_img_element ($self, $mime, $content, $filename) {
    
    $filename   = "image" unless defined $filename;
    my $uri     = URI->new("data:");
    $uri->media_type($mime);
    $uri->data($content);

    my $element = HTML::Element->new('img', 'src' => $uri, 'alt' => $filename);
    return $element;
}

sub inline_images ($self, $tree, $imgdb) {
    my @images                = $tree->look_down('_tag', 'img');

    foreach my $image (@images) {
        my $src = $image->attr('src');
        (my $name = $src) =~ s/cid:(.*)@.*/$1/;
        my $new = $imgdb->{$name};
        $image->replace_with($new);
    }
}


1;

