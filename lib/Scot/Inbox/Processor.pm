package Scot::Inbox::Processor;

use lib '../../../lib';
use Mojo::Base -base, -signatures;
use Data::Dumper::Concise;
use HTML::Element;
use URI;
use String::Clean::XSS;
use Try::Tiny;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::File qw(curfile);
use utf8;
use Scot::Inbox::Config qw(build_config);
use Scot::Inbox::Log qw(start_logging);
use Scot::Inbox::Imap;
use Scot::Inbox::Msgraph;
use Scot::Inbox::ScotApi;

# passed in from inbox.pl
has 'secrets';
has 'test';
has 'msv' => 1;
has 'msvlog' => '../var/log/msv.log';

# hash of configuration values
has 'config'    => sub ($self) {
    return build_config();
};

has 'log'       => sub ($self) {
    return start_logging($self->config->{log});
};

has 'scotapi'   => sub ($self) {
    return Scot::Inbox::ScotApi->new(
        log     => $self->log,
        config  => $self->config->{scotapi},
    );
};

has 'msvfilters'    => sub ($self) {
    return $self->config->{msv_filters};
};
has 'msv_msg_id_dbm' => '/opt/scot4-inbox/var/msv.dbm';

sub run ($self) {
    my $config  = $self->config;
    my $log     = $self->log;

    $log->debug("Starting Processor...");
    $log->debug("Config = ", {filter=>\&Dumper, value=> $config});

    my $target  = $self->config->{scot_queue};

    $log->debug("--- ");
    $log->info ("--- Processing mailbox for $target...");
    $log->debug("--- ");

    my $class       = $self->config->{class};
    my $client      = $class->new(
        log     => $log,
        config  => $self->config->{mboxconfig},
    );
    if (! defined $client) {
        $log->logdie("Failed to create $class, unable to process inbox.");
    }

    my $cursor  = $client->get_mail;
    my $count   = $cursor->count;
    my $index   = 0;

    $log->debug("[$target] $count messages found");

    while (my $msg  = $cursor->next) {
        $index++;
        $log->debug("[$target] processing message $index of $count");
        if (! defined $msg) {
            $log->warn("[$target] undefined message encountered, skipping");
            next;
        }
        if (defined $msg->{error}) {
            $log->error("[$target] Error in processing: $msg->{error}");
            next;
        }

        if (! $self->process_message($msg, $target)) {
            $self->log->error("[$target] unable to process the message! marking unread...");
            my @uids    = ($msg->{imap_uid});
            $client->client->unset_flag('\Seen', @uids);
        }
    }
    $log->info("Completed processing of $index messages");
}

sub delete ($self) {
    my $config  = $self->config;
    my $log     = $self->log;

    $log->debug("Starting Delete Job...");
    my $before_epoch    = $config->delete_before;
    $log->debug("   deleting email dated before $before_epoch");

    my $class   = $self->config->{class};
    my $client  = $class->new(log => $log, config => $self->config->{mboxconfig});
    if (! defined $client) {
        $log->logdie("Failed to create $class, unable to process inbox");
    }

    my $cursor  = $client->get_mail;
    my $count   = $cursor->count;
    my $index   = 0;
    my $target  = $config->{scot_queue};
    my @deluids = ();

    $log->debug("[$target] $count messages found");

    while (my $msg = $cursor->next) {
        $index++;
        $log->debug("[$target] processing message $index of $count");
        if (! defined $msg) {
            $log->warn("[$target] undefined message encountered, skipping");
            next;
        }
        if (defined $msg->{error}) {
            $log->error("[$target] Error in processing: $msg->{error}");
            next;
        }

        push @deluids, $msg->{imap_uid};
        #if (! $self->delete_message($msg, $target)) {
        #    $self->log->error("[$target] unable to process the message! marking unread...");
        #}
    }
    $client->delete_message(\@deluids);
    $log->info("Completed deletion job");
}

sub delete_message ($self, $msg, $target) {
    $self->log->debug("This would have deleted message: ",{filter=>\&Dumper, value => $msg});
}


sub process_message ($self, $msg, $target) {
    # $msg from Imap::get_message() line 196
    # $target is the inbox being processed
    if ( $self->is_health_check($msg) ) {
        $self->log->debug("[$target] -- Healthcheck received...");
        return 1;
    }
    if ( $self->already_in_scot($msg) ) {
        $self->log->debug("[$target] -- $msg->{message_id} already in SCOT");
        return 1;
    }

    return $self->process_alert($msg)      if ($target eq 'alertgroup');
    return $self->process_dispatch($msg)   if ($target eq 'dispatch');
    return $self->process_event($msg)      if ($target eq 'event');

}

sub process_alert ($self, $msg) {
    # 2 types of alerts, from splunk and generic
    my $subject = $msg->{subject};
    $self->log->debug("Looking at message $subject");
    my $json    = ($self->looks_like_splunk($subject)) 
                        ? $self->process_splunk_alert($msg) 
                        : $self->process_generic_alert($msg);
    $self->filter_msv($json) if $self->msv;
    my $status  = $self->create_alertgroup($json);
    if ( $status > 0 ) {
        $self->log->debug("Success creating alertgroup ".$status);
        return 1;
    }
    if ( $status < 0 ) {
        $self->log->debug("filtered msv alertgroup, not created");
        return 1;
    }
    $self->log->debug("Failed to create alertgroup from ",{filter=>\&Dumper, value => $json});
    return;
}

sub looks_like_splunk ($self, $subject) {
    return 1 if ($subject =~ /splunk alert/i);
    return 1 if ($subject =~ /splunk report/i);
    return undef;
}


sub filter_msv ($self, $json) {
    # this function operates by side-effect
    # $json is a hash ref and this function will alter its contents
    $self->log->debug("Filtering MSV Data");

    my $alerts  = $json->{alerts};
    my $msg_id  = $json->{message_id};

    my ($msv, $nomsv) = $self->scan_alerts($alerts);

    if (scalar(@$msv) > 0) {
        # write any msv rows to file for splunkforwarder
        $self->log->debug("Found msv data");
        $self->write_msv($msg_id, $json, $msv);
    }
    # remove base_event_uid and msv rows from $json and other uneeded fields
    $self->filter_schema($json);
    $json->{alerts} = $nomsv;
    # remove
    $self->log->trace("JSON after filter ",{filter=>\&Dumper, value => $json});
}

sub scan_alerts ($self, $alerts) {

    my @msv     = ();
    my @nomsv   = ();

    foreach my $href (@$alerts) {
        # pull the actual data from the structure needed by the Scot4 api
        my $row = $href->{data};
        if ($self->msv_present($row)) {
            push @msv, $self->format_for_msv($href);
            next;
        }
        # we should not show base_event_uid to the IR
        delete $row->{base_event_uid};
        push @nomsv, $href;
    }
    return \@msv, \@nomsv;
}

sub format_for_msv ($self, $href) {
    my %formatted   = ();
    foreach my $key (keys %{$href->{data}}) {
        $formatted{$key} = [ $href->{data}->{$key} ];
    }
    return \%formatted;
}

sub msv_present ($self, $row) {
    my $filters = $self->msvfilters;
    return if $self->invalid_filters($filters);

    # turn row into long string of csv
    my $concatrow = $self->concat_row($row);

    # see if we have any msv matches
    foreach my $type (keys %$filters) {
        foreach my $item (@{$filters->{$type}}) {
            if ($self->contains_item($concatrow, $item)) {
                $self->log->debug("Found $item in row!");
                return 1;
            }
        }
    }
    return;
}

sub invalid_filters ($self, $filters) {
    return (!defined $filters or ref($filters) ne "HASH");
}

sub contains_item ($self, $string, $item) {
    return $string =~ /$item/i;
}

sub filter_schema ($self, $json) {
    # remove these because API cant currently accept them
    delete $json->{columns};
    delete $json->{links};
    delete $json->{search};
    my @new = ();
    foreach my $href (@{$json->{alert_schema}}) {
        if ( $href->{schema_key_name} ne "base_event_uid" ) {
            push @new, $href;
        }
    }
    $json->{alert_schema} = \@new;
}

sub write_msv ($self, $msg_id, $json, $msv) {
    my %seendb;
    my $file = $self->msv_msg_id_dbm;
    dbmopen %seendb, $file, 0666 or $self->log->logdie("Cant open $file: $!");
    
    if (exists $seendb{$msg_id}) {
        $self->log->debug("Seen $msg_id msv data before, skipping...");
        return;
    }
    $self->log->debug("adding $msg_id to msv seen dbm");
    $seendb{$msg_id}++;

    $self->log->debug("MSV array = ", {filter=>\&Dumper, value=> $msv});

    foreach my $href (@$msv) {
        $href->{alert_name} = $json->{subject};
        $href->{columns}    = $json->{columns};
        $href->{links}      = $json->{links};
        $href->{search}     = $json->{search};

        $self->write_msv_row($href);
    }

    dbmclose %seendb or $self->log->logdie("Failed to close $file: $!");
}

sub concat_row ($self, $row) {
    return join(',', values %$row);
}

sub write_msv_row ($self, $row) {
    $self->log->debug("writing data: ",{filter=>\&Dumper, value => $row});
    my $log     = $self->msvlog;
    if (open(my $fh, '>>', $log)) {
        my $text    = (ref($row) eq "HASH") ? encode_json($row) : Dumper($row);
        print $fh $text."\n";
        $self->log->debug("wrote row to $log");
        close $fh;
    } 
    else {
        $self->log->error("Unable to write to $log: $!");
    }
}

sub create_alertgroup ($self, $json) {

    if (scalar(@{$json->{alerts}}) < 1) {
        $self->log->debug("Alerts filtered or not present, skipping...");
        return -1;
    }

    my $response= $self->scotapi->create_alertgroup($json);
    if (defined $response) {
        my $rhash = try   { decode_json $response; }
                    catch {
                        $self->log->error("error decoding response: ",
                            {filter=>\&Dumper, value=>$response});
                    };
        $self->log->debug("response => ",{filter=>\&Dumper, value=>$rhash});
        return 1;
    }
    $self->log->error("undefined response from ScotApi!");

    return;
}


sub process_splunk_alert ($self, $msg) {
    $self->log->debug("Processing a splunk generated alert...");
    my ($html, 
        $plain, 
        $tree)      = $self->preparse($msg);
    my @anchors     = $tree->look_down('_tag', 'a');
    my @links       = $self->get_splunk_links(@anchors);
    my ($alertname,
        $search,
        $tags)      = $self->get_splunk_report_info($tree);
    my ($alerts,
        $columns)   = $self->get_alert_results($tree, $alertname, $search);

    my $alertschema = $self->build_alert_schema($columns);

    my %json    = (
        owner       => 'scot-alerts',
        tlp         => 'unset',
        view_count  => 0,
        message_id  => $msg->{message_id},
        subject     => $msg->{subject},
        sources     => [qw(email splunk)],
        tags        => $tags,
        alerts      => $self->build_alerts($alerts),
        alert_schema => $alertschema,
        back_refs   => $links[1]->{link},
        # additons to discuss with greg
        # (will delete in filter_schema after writing MSV log)
        columns   => $columns, # to get column order from splunk
        links     => \@links,
        search      => $search,
    );
    $self->log->trace("built json ", {filter => \&Dumper, value => \%json});

    return wantarray ? %json : \%json;
}

sub build_alerts ($self, $alerts) {
    my @new = map { { data => $_ } } @$alerts;
    return \@new;
}

sub build_alert_schema ($self, $columns) {
    my @schema  = ();
    my $index   = 0;
    $self->log->debug("building alert schema");
    for ($index = 0; $index < scalar(@$columns); $index++) {
        push @schema, { 
            schema_key_name     => $columns->[$index],
            schema_key_order    => $index,
        };
    }
    return \@schema;
}

sub get_splunk_links ($self, @anchors) {
    my @links = map {
        { subject => join(' ', $_->content_list), link => $_->attr('href'), }
    } @anchors;
    $self->log->debug("Splunk Links = ",join(', ',map {$_->{href}} @links));
    return wantarray ? @links : \@links;
}

sub get_splunk_report_info ($self, $tree) {
    my $alertname   = "splunk parse error";
    my $search      = "See Source for Search";
    my @tags        = (qw(parse_error));

    my $top_table   = ($tree->look_down('_tag', 'table'))[0];

    if ($top_table) {
        my @tds = $top_table->look_down('_tag', 'td');
        $search = (scalar(@tds) > 1 ) 
            ? $tds[1]->as_text
            : "splunk not sending search terms";
        $alertname = (defined $tds[0]) 
            ?  $tds[0]->as_text
            : "unknown alert name";
        @tags = $self->extract_splunk_tags($search);
    }
    $self->log->debug("alertname = $alertname");
    $self->log->debug("search    = $search");
    $self->log->debug("tags      = ", {filter => \&Dumper, value => \@tags});
    return $alertname, $search, \@tags;
}

sub get_alert_results ($self, $tree, $alertname, $search) {
    my @results = ();
    my @columns = ();
    $self->log->debug("getting alert results");
    my $table   = ($tree->look_down('_tag', 'table'))[1];

    if (defined $table) {
        $self->log->debug("found a table");
        my @rows    = $table->look_down('_tag', 'tr');
        my $header  = shift @rows;
        @columns    = $self->get_columns($header);
        @results    = $self->parse_rows(\@columns, \@rows);
    }
    # hack to add emlat_score until api handles properly
    push @columns, 'emlat_score';

    $self->log->debug(scalar(@results)." results and ".scalar(@columns)." columns");
    return \@results, \@columns;
}

sub get_columns ($self, $header) {
    $self->log->debug("getting columns");
    my @columns = map { $_->as_text; } $header->look_down('_tag', 'th');

    if (scalar(@columns) == 0) {
        # outlook often rewrites th's to td's 
        @columns = map { $_->as_text; } $header->look_down('_tag', 'td');
    }
    
    # may not be necessary for mysql
    # . in column name will break mongo.
    s/\./-/g for @columns; 
    $self->log->debug("got columns: ".join(', ',@columns));
    return wantarray ? @columns : \@columns;
}

sub parse_rows ($self, $columns, $rows) {
    my $empty_replace = 1;
    my @results       = ();

    $self->log->debug("Getting Rows");

    foreach my $row (@$rows) {
        my %rowresult;
        my @values  = $row->look_down('_tag', 'td');
        for (my $i = 0; $i < scalar(@values); $i++) {
            my $name = $columns->[$i];
            $name = "c".$empty_replace++ if (! $name);
            my $cell = $values[$i];
            my @children = map { 
                ref($_) eq "HTML::Element" ? convert_XSS($_->as_text) : $_ 
            } $cell->content_list;
            # scot3 stored as array
            # $rowresult{$name} = \@children;
            # but scot4 needs concatenated string with  \n separation
            # $rowresult{$name} = join('\n', @children);
            # $rowresult{$name} = join(' ', @children);
            $rowresult{$name} = join("\n", grep { $_ ne " " } @children);
        }
        # hack to add emlat_score to every alert until api can handle this
        $rowresult{'emlat_score'} = 0;
        push @results, \%rowresult;
    }
    $self->log->trace("Got results: ",{filter=>\&Dumper, value=> \@results});
    return wantarray ? @results : \@results;
}

sub extract_splunk_tags ($self, $search) {
    my @tags    = ();
    my $regex   = qr{
        (sourcetype=.*?)\ |
        (index=.*?)\ |
        (tag=.*?)\ |
        (source=.*?)\
    }xms;

    foreach my $match ($search =~ m/$regex/g) {
        next if (! defined $match);
        next if ($match eq '');
        push @tags, $match;
    }

    return wantarray ? @tags : \@tags;
}

sub process_generic_alert ($self, $msg) {
    $self->log->debug("Processing a generic alert...");
    my ($html, 
        $plain, 
        $tree)      = $self->preparse($msg);

    my @alerts  = (
        { data => { alert_text    => $html }},
    );
    my $tags    = [ 'generic_alert' ];

    # TODO: determine payload SCOT4 requires
    my %json    = (
        owner       => '',
        tlp         => 'unset',
        view_count  => 0,
        message_id  => $msg->{message_id},
        subject     => $msg->{subject},
        tags        => $tags,
        sources     => [qw(email)],
        alerts      => \@alerts,
    );

    return wantarray ? %json : \%json;
}

sub process_dispatch ($self, $msg) {
    $self->log->debug("Processing a dispatch...");
    my ($html, 
        $plain, 
        $tree) = $self->preparse($msg);

    my $tlp         = $self->find_tlp($plain);
    my $entry       = $self->build_entry($tree, $tlp);

    $self->log->trace("entry = ",{filter => \&Dumper, value => $entry});

    my %json    = (
        dispatch    => {
            subject     => $msg->{subject},
            message_id  => $msg->{message_id},
            owner       => 'scot-feeds',
            tags        => $self->build_tags($msg),
            sources     => $self->build_sources($msg),
            tlp         => $tlp,
        },
        entry   => $entry,
    );

    $self->log->trace("Dispatch = ", {filter => \&Dumper, value => \%json});

    my $resp = $self->scotapi->create_dispatch(\%json);

    if (! defined $resp->{dispatch} || ! defined $resp->{entry} ) {
        $self->log->error("Error creating either dispatch or entry!");
        $self->log->error("resp = ",{filter =>\&Dumper, value => $resp});
        return;
    }

    return 1;
}

sub process_event ($self, $msg) {
    $self->log->debug("Processing a event...");
    my ($html, $plain, $tree)   = $self->preparse($msg);

    my $subject = $msg->{subject};
    my $tags    = $self->build_tags($msg);
    my $sources = $self->build_sources($msg);

    if ( $self->is_event_api($tree) ) {
        ($subject, $tags, $sources) = $self->get_api_basics($tree);
    }

    my $attachments = $msg->{attachments};

    my %json    = (
        event   => {
            subject     => $subject,
            tags        => $tags,
            sources     => $sources,
        },
        entry       => $self->build_entry($tree, 'unset'),
        attachments => $attachments,
    );
    return wantarray ? %json : \%json;
}

sub is_event_api ($self, $tree) {
	my $table   = ($tree->look_down('_tag', 'table'))[0];
	return undef if ( ! defined $table);
	
    my @cells   = $table->look_down('_tag','td');
    my @needed_elements = qw(subject sources tags);
    my %found   = ();

    foreach my $cell (@cells) {
        my $text = $cell->as_text;
        if ( grep {/$text/i} @needed_elements ) {
            $found{$text}++;
        }
    }
    return ( $found{subject} && $found{sources} && $found{tags} );
}

sub get_api_basics($self, $tree) {
	my $table   = ($tree->look_down('_tag', 'table'))[0]->detach_content;
	my @cells   = $table->look_down('_tag', 'td');

	my ($subject, $tags, $sources);

	for (my $i = 0; $i <scalar(@cells); $i+=2) {
		my $j = $i + 1;

		my $key = $cells[$i];
		my $val = $cells[$j];

		$key = lc($key->as_text) if (defined $key and ref($key) eq "HTML::Element");
		$val = lc($val->as_text) if (defined $val and ref($val) eq "HTML::Element");

		$subject = $val if ($key eq "subject");
		$tags    = [ map { lc($_); } split(/[ ]*,[ ]*/, $val) ] if ($key eq "tags");
		$sources = [ map { lc($_); } split(/[ ]*,[ ]*/, $val) ] if ($key eq "sources");
	}

	return $subject, $tags, $sources;
}

sub build_entry ($self, $tree, $tlp) {
    $self->log->debug("building entry...");
    if (! defined $tree or ref($tree) eq "") {
        $self->log->warn("html tree incorrect.");
    }
    no warnings;
    my $html    = $tree->as_HTML;
    my $entry   = {entry_data => $html, tlp => $tlp};
    $self->log->trace("entry = ", {filter => \&Dumper, value => $entry});
    return $entry;
}

sub build_tags ($self, $msg) {
    return [];
}

sub build_sources ($self, $msg) {
    return ['email', $msg->{from} ];
}

sub is_health_check ($self, $msg) {
    my $subject = $msg->{subject};
    return ($subject =~ /Scot Health Check/i);
}

sub already_in_scot ($self, $msg) {
    # until api implements always assume not
    $self->log->warn("Deduplication test for message not implemented yet!");
    return undef;
    my $type    = $self->config->{scot_queue};
    return $self->scotapi->msgid_in_scot($type, $msg->{message_id});
}

sub get_tlp ($self, $data, $parent) {
    my @valid   = (qw(unset white green amber amber+strict red black));
    my $tlp     = $data->{tlp};
    return $tlp if (defined $tlp and $tlp ne "" and grep {/$tlp/} @valid);
    return 'unset';
}

sub preparse ($self, $msg) {
    my ($html, $plain)  = @$msg{'body', 'plain'};
    if ($self->body_not_html($html)) {
        $self->log->warn("HTML body not detected");
        $html = $self->wrap_non_html($html);
    }
    my $tree = $self->build_html_tree($html);
    $self->log->trace("Preparse HTML = $html");
    $self->log->trace("Preparse plain = $plain");
    $self->log->debug("Tree is a ".ref($tree));
    return $html, $plain, $tree;
}

sub build_html_tree ($self, $body) {

    if (! defined $body) {
        $self->log->error("undefined body, skipping");
        return undef;
    }

    my $tree    = HTML::TreeBuilder->new;
    $tree      ->implicit_tags(1);
    $tree      ->implicit_body_p_tag(1);
    $tree      ->parse_content($body);

    if ( ! defined $tree ) {
        $self->log->error("Unable to parse HTML. Body = ", {filter=>\&Dumper, value=>$body});
        return undef;
    }

    return $tree;
}

sub body_not_html ($self, $html) {
    if ( ! defined $html ) {
        return 1;
    }
    return ! ($html =~ /\<html.*\>/i or $html =~ /DOCTYPE html/);
}

sub wrap_non_html ($self, $html, $plain) {
    return qq{
        <html>
          <body>
            <pre>$plain</pre>
          </body>
        </html>
    };
}

sub find_tlp ($self, $text) {
    foreach my $line (split(/\n/, $text)) {
        (my $level) = ($line =~ m/TLP:(.*) DOE/);
        if (defined $level) {
            return lc($level);
        }
    }
    return 'unset';
}

1;




