package Scot::Inbox::ScotApi;

# use lib '../../../lib';
use Data::Dumper::Concise;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Base -base, -signatures;
use MIME::Base64;

has 'log';
has 'config';

has auth_header => sub ($self) {
    if (defined $self->config->{api_key}) {
        return "apikey ".$self->config->{api_key};
    }
    chomp(
        my $enc = encode_base64(join(':', $self->config->{user}, $self->config->{pass}))
    );
    return "basic $enc";
};

has ua  => sub ($self) {
    my $ua  = Mojo::UserAgent->new();
    $ua->proxy->detect;
    $ua->on(start => sub ($ua, $tx) {
        $tx->req->headers->header(
            Authorization => $self->auth_header
        )
    });
    return $ua;
};

sub fetch ($self, $type, $id) {
    my $uri = $self->build_uri_from_msg($type, $id);
    return $self->get($uri);
}
    
sub build_uri_from_msg ($self, $type, $id) {
    return join('/', $self->config->{uri_root},
                     $type,
                     $id);
}

sub get ($self, $uri) {
    my $tx  = $self->ua->insecure($self->config->{insecure})->get($uri);
    my $res = $tx->result;
    my $code = $res->code;

    if ($code != 200) {
        $self->log->error("Error GET $uri. Code = $code");
        return undef;
    }
    return decode_json($res->body);
}

sub post ($self, $uri, $post_data) {
    $self->log->debug("Using auth header: ".$self->auth_header);
    my $tx  = $self->ua->insecure($self->config->{insecure})->post(
        $uri => {Accept => '*/*'} => json => $post_data
    );
    my $res = $tx->result;
    my $code= $res->code;

    if ( $code != 200 and $code != 202 ) {
        $self->log->error("Failed POST to $uri! ",{filter=>\&Dumper, value=>$res});
        return { error => "Failed POST to $uri" };
    }
    $self->log->debug("After POST. returning ".$res->body);
    return $res->body;
}

sub put ($self, $uri, $put_data) {
    my $tx = $self->ua->insecure($self->config->{insecure})->put(
        $uri => {Accept => '*/*'} => json => $put_data
    );
    my $res  = $tx->result;
    my $code = $res->code;
    return { error => "Failed POST to $uri" } if ($code != 200 and
                                                  $code != 202);

    return $res->body;
}

sub patch ($self, $uri, $put_data) {
    my $tx = $self->ua->insecure($self->config->{insecure})->patch(
        $uri => {Accept => '*/*'} => json => $put_data
    );
    my $res  = $tx->result;
    my $code = $res->code;
    return { error => "Failed POST to $uri" } if ($code != 200 and
                                                  $code != 202);

    return $res->body;
}

sub delete ($self, $uri) {
    my $tx   = $self->ua->insecure($self->config->{insecure})->delete($uri);
    my $res  = $tx->result;
    my $code = $res->code;
    return { error => "Failed DELETE to $uri" } if ($code != 200 and
                                                    $code != 202);

    return $res->body;
}

sub update_scot3_alertgroup ($self, $alertgroup, $results) {
    my $uri = join('/', $self->config->{uri_root},
                        'update_alertgroup_flair');
    my $body = $self->post($uri, $results);
    #TODO: create update_alertgroup_flair route in scot3 to do the dirty work
}

sub flair_update_scot4 ($self, $data) {
    my $uri = $self->config->{uri_root}."/flairupdate";
    return $self->post($uri, $data);
}

sub upload_file_scot4 ($self, $filename) {
    my $uri = $self->config->{uri_root}."/file";
    my $data= { image => { file => $filename } };
    my $tx  = $self->ua->insecure($self->config->{insecure})->post(
        $uri => form => $data
    );
    my $res  = $tx->result;
    my $code = $res->code;
    if ($code != 200) {
        $self->log->error("Error ($code) Uploading $filename");
        return { error => "failed to upload $filename to $uri" };
    }
    return $res->body;
} 

sub create_alertgroup ($self, $json) {
    # scot4
    my $uri     = $self->config->{uri_root}."/alertgroup/";
    my $data    = { alertgroup => $json, };
    $self->log->debug("POST $uri ", {filter=>\&Dumper, value=>$json});
    return $self->post($uri, $data);
}

sub create_dispatch ($self, $json) {
    my $entry_text  = delete $json->{entry};
    my $uri         = $self->config->{uri_root}."/dispatch/";
    my $dispatch    = decode_json $self->post($uri, $json);
    $self->log->debug("post returns: ",{filter =>\&Dumper, value => $dispatch});

    if ( defined $dispatch and $dispatch->{id} > 0 ) {
        $self->log->debug("creating entry");
        my $entry  = decode_json $self->create_entry("dispatch", $dispatch->{id}, $entry_text);
        $self->log->debug("entry = ",{filter=>\&Dumper, value => $entry});
        if ( defined $entry and $entry->{id} > 0 ) {
            return {
                dispatch    => $dispatch,
                entry       => $entry,
            };
        }
    }
    return {
        dispatch    => undef,
        entry       => undef,
    };
}

sub create_event ($self, $json) {
    my $entry_text  = delete $json->{entry};
    my $uri         = $self->config->{uri_roo}."/entry/";
    my $event       = $self->post($uri, $json);


    if (defined $event and $event->{id} > 0 ) {
        my $entry = $self->create_entry("evetn", $event->{id}, $entry_text);
        if (defined $entry and $entry->{id} > 0 ) {
            return {
                event   => $event,
                entry   => $entry,
            };
        }
    }
    return {
        event   => undef,
        entry   => undef,
    };
}



sub create_entry ($self, $target, $id, $entry) {
    my $uri     = $self->config->{uri_root}."/entry/";
    my $data    = {
        entry   => {
            owner           => 'scot-feeds',
            tlp             => $entry->{tlp},
            parent_entry    => 0,
            target_type     => $target,
            target_id       => $id,
            entry_data      => { html => $entry->{entry_data}},
        }
    };
    my $json = encode_json $data;
    $self->log->debug("POST $uri -d'".encode_json $json."'");
    return $self->post($uri, $data);
}

sub get_alertgroups ($self, $parameters={}, $sort={}, $limit=50, $skip=0) {
    my $uri = $self->config->{uri_root}."/alertgroup/";
    return $self->get($uri);
}

sub msgid_in_scot ($self, $type, $msgid) {
    my $uri = $self->config->{uri_root} .
              "/$type/" .
              "?message_id=$msgid";
    my $result  = $self->get($uri);
    if (defined $result) {
        $self->log->debug("Found $type with message_id of $msgid");
        return 1;
    }
    $self->log->debug("No matching $type with message_id of $msgid");
    return undef;
}


1;
