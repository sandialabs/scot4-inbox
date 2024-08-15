package Scot::Inbox::Log;

require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(start_logging);

use strict;
use warnings;

use Log::Log4perl;
use Data::Dumper::Concise;
use experimental 'signatures';

sub start_logging ($config) {
    my $name    = $config->{name};
    my $setup   = $config->{config};

    if ( ! Log::Log4perl->initialized) {
        if (is_string_config($setup)) {
            Log::Log4perl->init_once(\$setup);
        }
        else {
            my $fqn = find_config($setup);
            if (defined $fqn) {
                Log::Log4perl->init_once($fqn);
            }
            else {
                die "Failed to init logging!";
            }
        }
    }
    if (defined $name) {
        my $log = Log::Log4perl->get_logger($name);
        $log->info("$0 logging to $name...");
        return $log;
    }
    die "Log Name not provided!";
}

sub is_string_config ($config) {
    return (ref($config) eq "" and defined($config));
}

sub is_readable ($file) {
    if ( -r $file ) {
        return $file;
    }
    die "Unable to read config file $file";
}

sub find_config ($filename) {
    if (is_fully_qualified($filename) or is_relative_path($filename)) {
        return is_readable($filename);
    }
    if (is_tilde_path($filename) ) {
        my $newname = glob($filename);
        return is_readable($newname);
    }
    my @paths   = (qw(
        .
        ~/Scot/Inbox/etc
        /opt/Scot/Inbox/etc
    ));
    foreach my $p (@paths) {
        my $f = (glob(join('/', $p, $filename)))[0];
        next if ! defined $f;
        return $f if (-r $f);
    }
    die "Unable to find log config file $filename in path: ".join(":",@paths);
}

sub is_fully_qualified ($f) {
    return ($f =~ /^\/\.+/);
}

sub is_tilde_path ($f) {
    return ($f =~ /^~.+/);
}

sub is_relative_path ($f) {
    return ($f =~ /^\.+\/.+/);
}
1;

