package App::YoutubeDlIf;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use IPC::System::Options qw(system readpipe);
use Regexp::Pattern::YouTube;
use YouTube::Util;

our %SPEC;

our %args_common = (
    urls_or_ids => {
        'x.name.is_plural' => 1,
        'x.name.singular' => 'url_or_id',
        schema => ['array*', of=>'str*', min_len=>1],
        req => 1,
        pos => 0,
        greedy => 1,
    },
    log_file => {
        summary => 'File that contains list of download filenames',
        schema => 'str*', # XXX filename
        default => do {
            my $path;
            my @paths = (
                "$ENV{HOME}/notes/download-logs.org",
                "$ENV{HOME}/download-logs.org",
            );
            for my $p (@paths) {
                if (-f $p) {
                    $path = $p; last;
                }
            }
            die "Cannot find download log file, please specify using ".
                "--log-file or put the log file in one of: ".
                (join ", ", @paths) unless $path;
            $path;
        },
    },
    if_duration_not_shorter_than => {
        #schema => 'duration*', # XXX duration coercer parses 01:00 as 1 hour 0 minutes instead of 1 minute 0 seconds
        schema => 'str*',
        tags => ['category:filtering'],
    },
    if_duration_not_longer_than => {
        #schema => 'duration*',
        schema => 'str*',
        tags => ['category:filtering'],
    },
);

our %arg_if_not_yet = (
    if_not_yet => {
        summary => 'If set, only download videos that are not yet downloaded',
        schema => 'bool',
        description => <<'_',

When set to true, youtube-dl-if will first extract downloaded video ID's from
filenames or URL's or video ID's listed in a text file (specified via
`--log-file`), e.g.:

    35682594        Table Tennis Shots- If Were Not Filmed, Nobody Would Believe [HD]-dUjxqFbWzQo.mp4       date:[2019-12-29 ]

or:

    https://www.youtube.com/embed/U9v2S49sHeQ?rel=0

or:

    U9v2S49sHeQ

When a video ID in the argument is found then it is assumed to be already
downloaded in the past and will not be downloaded again.

Limitations: youtube ID is currently only looked up in arguments, so if you
download a playlist, the items in the playlist are not checked against the ID's
in the log file. Another limitation is that you currently have to maintain the
log file yourself, e.g. by using 'ls -l >> ~/download-logs.org' everytime you
finish downloading files.

_
        tags => ['category:filtering'],
    },
);

sub _search_id_in_log_file {
    my ($id, $path) = @_;

    state $cache = do {
        my %mem;
        open my($fh), "<", $path or die "Can't open log file '$path': $!";
        while (my $line = <$fh>) {
            chomp $line;
            if (my $video_id = YouTube::Util::extract_youtube_video_id($line)) {
                next if $mem{$video_id};
                $mem{$video_id} = $line;
            }
        }
        #use DD; dd \%mem;
        \%mem;
    };

    $cache->{$id};
}

sub _dur2sec {
    my $dur = shift;
    return undef unless defined $dur;
    if ($dur =~ /\A(?:(\d+):)?(?:(\d{1,2}):)(\d{1,2})$/) {
        return ($1 // 0)*3600 + $2*60 + $3;
    } else {
        die "Can't parse duration '$dur'";
    }
}

$SPEC{youtube_dl_if} = {
    v => 1.1,
    summary => 'Download videos using youtube-dl with extra selection/filtering',
    description => <<'_',

This is a wrapper for **youtube-dl**.

_
    args => {
        %args_common,
        %arg_if_not_yet,
    },
    args_rels => {
        #dep_any => [log_file => ['if_not_yet']], # XXX currently will fail if if_not_yet not specified because of the log_file's default
    },
    deps => {
        prog => 'youtube-dl',
    },
};
sub youtube_dl_if {
    my %args = @_;

    my $re_video_id = $Regexp::Pattern::YouTube::RE{video_id}{pat} or die;
    $re_video_id = qr/\A$re_video_id\z/;
    #use DD; dd $re_video_id;

    my @argv_for_youtube_dl;
  ARG:
    for my $arg (@{$args{urls_or_ids}}) {
      FILTER: {
            # looks like an option name
            last FILTER if $arg =~ /\A--?\w+/ && $arg !~ $re_video_id;

            my $video_id = YouTube::Util::extract_youtube_video_id($arg);
            if ($video_id) {
                log_trace "Argument %s has video ID %s", $arg, $video_id;
                if ($args{if_not_yet}) {
                    if (my $filename = _search_id_in_log_file($video_id, $args{log_file})) {
                        log_info "Argument %s (video ID %s) has been downloaded (%s), skipped", $arg, $video_id, $filename;
                        next ARG;
                    } else {
                        log_trace "Argument %s (video ID %s) is not in downloaded list", $arg, $video_id;
                    }
                }
            }
            if (defined $args{if_duration_not_shorter_than} || defined $args{if_duration_not_longer_than}) {
                my $min_secs = _dur2sec($args{if_duration_not_shorter_than});
                my $max_secs = _dur2sec($args{if_duration_not_longer_than});
                my $video_dur = readpipe({log=>1, die=>1}, "youtube-dl --no-playlist --get-duration -- '$arg' 2>/dev/null");
                my $video_secs = _dur2sec($video_dur);
                if (defined $min_secs && $video_secs < $min_secs) {
                    log_info "Argument %s (video ID %s, duration %s) is too short (min %s), skipped", $arg, $video_id, $video_dur, $args{if_duration_not_shorter_than};
                    next ARG;
                }
                if (defined $max_secs && $video_secs > $max_secs) {
                    log_info "Argument %s (video ID %s, duration %s) is too long (min %s), skipped", $arg, $video_id, $video_dur, $args{if_duration_not_longer_than};
                    next ARG;
                }
            }
        } # FILTER
        push @argv_for_youtube_dl, $arg;
    }

    system({log=>1, die=>1}, "youtube-dl", @argv_for_youtube_dl);
    [200];
}

$SPEC{youtube_dl_if_not_yet} = {
    v => 1.1,
    summary => 'Download videos using youtube-dl if not already downloaded',
    description => <<'_',

This is a shortcut for:

    % youtube-dl-if --if-not-yet ...

_
    args => {
        %args_common,
    },
    args_rels => {
    },
    deps => {
        prog => 'youtube-dl',
    },
};
sub youtube_dl_if_not_yet {
    my %args = @_;
    youtube_dl_if(if_not_yet=>1, %args);
}

1;
# ABSTRACT:

=head1 DESCRIPTION


=head1 SEE ALSO

L<App::YouTubeUtils> for other YouTube-related CLIs.

=cut
