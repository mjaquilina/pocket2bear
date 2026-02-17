#!/usr/bin/env perl

use strict;
use warnings;
use JSON;
use LWP::UserAgent;
use URI::Escape;
use File::Spec;
use DateTime;
use DateTime::Format::ISO8601;

my $POCKET_API_KEY = $ENV{POCKET_API_KEY};
my $BEAR_API_TOKEN = $ENV{BEAR_API_TOKEN};
my $POCKET_BASE_URL = "https://public.heypocketai.com/api/v1";
my $SYNC_STATE_FILE = File::Spec->catfile($ENV{HOME}, '.pocket_bear_sync_state.json');

# Tag to use in bear
my $BEAR_TAG = "pocket";

sub load_sync_state {
    my $state_file = shift;
    
    if (-e $state_file) {
        open my $fh, '<', $state_file or die "Cannot read state file: $!";
        local $/;
        my $json = <$fh>;
        close $fh;
        return decode_json($json);
    }
    
    return {
        synced_ids => [],
        last_sync => undef
    };
}

sub save_sync_state {
    my ($state_file, $state) = @_;
    
    open my $fh, '>', $state_file or die "Cannot write state file: $!";
    print $fh encode_json($state);
    close $fh;
}

sub get_pocket_recordings {
    my $hours = shift;
    
    die "POCKET_API_KEY environment variable not set\n" unless $POCKET_API_KEY;
    
    my $ua = LWP::UserAgent->new(timeout => 30);
    my $url = "$POCKET_BASE_URL/public/recordings";
    
    my $response = $ua->get(
        $url,
        'Authorization' => "Bearer $POCKET_API_KEY",
        'Content-Type' => 'application/json'
    );
    
    unless ($response->is_success) {
        warn "Error fetching Pocket recordings: " . $response->status_line . "\n";
        return [];
    }
    
    my $data = decode_json($response->decoded_content);
    my $recordings = $data->{data} || [];
    
    my $threshold = DateTime->now->subtract(hours => $hours);
    
    my @recent;
    foreach my $rec (@$recordings) {
        my $rec_time = $rec->{created_at} || $rec->{updated_at};
        next unless $rec_time;
        
        $rec_time =~ s/Z$/+00:00/;
        my $rec_dt = eval { DateTime::Format::ISO8601->parse_datetime($rec_time) };
        
        if ($rec_dt && $rec_dt >= $threshold) {
            push @recent, $rec;
        }
    }
    
    return \@recent;
}

sub get_recording_details {
    my $recording_id = shift;
    
    die "POCKET_API_KEY environment variable not set\n" unless $POCKET_API_KEY;
    
    my $ua = LWP::UserAgent->new(timeout => 30);
    my $url = "$POCKET_BASE_URL/public/recordings/$recording_id?include_summarizations=1";
    
    my $response = $ua->get(
        $url,
        'Authorization' => "Bearer $POCKET_API_KEY",
        'Content-Type' => 'application/json'
    );

    unless ($response->is_success) {
        warn "Error fetching recording details for $recording_id: " . $response->status_line . "\n";
        return undef;
    }
    
    my $x = decode_json($response->decoded_content);
	return $x->{data};
}

sub create_bear_note {
    my ($title, $content, $tags) = @_;
    
    die "BEAR_API_TOKEN environment variable not set\n" unless $BEAR_API_TOKEN;
    
    # Add tags to content
    if ($tags && @$tags) {
        my $tag_string = join(' ', map { "#$_" } @$tags);
	$content = "$tag_string\n\n$content";
    }
    
    my %params = (
        title => $title,
        text => $content,
        token => $BEAR_API_TOKEN,
        show_window => 'no'
    );
    
    my $query_string = join('&', map { 
        uri_escape($_) . '=' . uri_escape_utf8($params{$_}) 
    } keys %params);
    
    my $url = "bear://x-callback-url/create?$query_string";
    
    my $result = system('open', $url);
    
    return $result == 0;
}

sub format_summary_content {
    my $recording = shift;
    my @parts;
    
    my $title = $recording->{title} || 'Untitled Recording';
    my $created_at = $recording->{created_at} || '';
    my $duration = $recording->{duration} || 'Unknown';
    
    push @parts, "**Date:** $created_at";
    push @parts, "**Duration:** $duration";
    push @parts, "";
    
    my $summary = $recording->{summarizations}{v2_summary}{markdown};
    my $summary_text = '';
    
    if (ref($summary) eq 'HASH') {
        $summary_text = $summary->{text} || '';
    } elsif ($summary) {
        $summary_text = "$summary";
    }
    
    if ($summary_text) {
        push @parts, $summary_text;
    }
    
    return join("\n", @parts);
}

sub main {
    print "Starting Pocket to Bear sync...\n";
    
    unless ($POCKET_API_KEY) {
        print "ERROR: POCKET_API_KEY environment variable not set\n";
        print "Export your Pocket API key: export POCKET_API_KEY='pk_xxx'\n";
        return 1;
    }
    
    unless ($BEAR_API_TOKEN) {
        print "ERROR: BEAR_API_TOKEN environment variable not set\n";
        print "Get token from Bear: Help > API Token > Copy Token\n";
        print "Then export it: export BEAR_API_TOKEN='your_token'\n";
        return 1;
    }
    
    my $state = load_sync_state($SYNC_STATE_FILE);
    my %synced_ids = map { $_ => 1 } @{$state->{synced_ids}};
    
    print "Fetching recordings from last 48 hours...\n";
    my $recordings = get_pocket_recordings(48);
    my $count = scalar @$recordings;
    print "Found $count recordings from last 48 hours\n";
    
    my $new_syncs = 0;
    foreach my $recording (@$recordings) {
        my $recording_id = $recording->{id};
        
        unless ($recording_id) {
            warn "Warning: Recording without ID, skipping\n";
            next;
        }
        
        if ($synced_ids{$recording_id}) {
            print "Skipping already synced recording: $recording_id\n";
            next;
        }
       
        print "Fetching details for recording $recording_id...\n";
        my $details = get_recording_details($recording_id);

        unless ($details) {
            warn "Failed to fetch details for $recording_id, skipping\n";
            next;
        }

        unless ($details->{summarizations}{v2_summary})
        {
            print "Skipping recording without summarization: $recording_id";
            next;
        }
        
        my $note_title = "" . ($details->{title} || $recording_id);
        my $content = format_summary_content($details);
        
        print "Creating Bear note: $note_title\n";
        my $success = create_bear_note($note_title, $content, [$BEAR_TAG]);
        
        if ($success) {
            $synced_ids{$recording_id} = 1;
            $new_syncs++;
            print "✓ Successfully synced recording $recording_id\n";
        } else {
            warn "✗ Failed to create Bear note for $recording_id\n";
        }
    }
    
    $state->{synced_ids} = [keys %synced_ids];
    $state->{last_sync} = DateTime->now->iso8601;
    save_sync_state($SYNC_STATE_FILE, $state);
    
    print "\nSync complete! Synced $new_syncs new recordings.\n";
    print "Total recordings tracked: " . scalar(keys %synced_ids) . "\n";
    return 0;
}

exit main();

