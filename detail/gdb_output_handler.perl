use strict;
use warnings;

my $session = $ENV{"kak_session"};
my $tmpdir = $ENV{"tmpdir"};

sub escape {
    my $command = shift;
    $command =~ s/'/''/g;
    return "'${command}'";
}

sub send_to_kak {
    my $command = join(' ', @_);
    print("${command}\n");
    return;

    # what a silly pattern
    my $pid = open(CHILD_STDIN, "|-");
    defined($pid) || die "can't fork: $!";
    $SIG{PIPE} = sub { die "child pipe broke" };
    if ($pid > 0) { # parent
        print CHILD_STDIN $command;
        close(CHILD_STDIN) || warn "child exited $?";
    } else { # child
        exec("kak", "-p", $session) || die "can't exec program: $!";
    }
}

my $parser_input;
sub parse_value { 
    if ($parser_input =~ m/\G("|{|\[)/gc) {
        if ($1 eq '"') {
            return parse_string();
        } elsif ($1 eq '[') {
            return parse_array();
        } elsif ($1 eq '{') {
            return parse_object();
        }
    }
    return 1;
}
# returns an array, and advances to the character after ]
sub parse_array {
    my @res;
    if ($parser_input =~ m/\G]/gc) {
        return (0, \@res);
    }
    while (1) {
        my ($err, $val) = parse_value();
        if ($err) { 
            return 1; 
        }
        push(@res, $val);
        if ($parser_input =~ m/\G(,|])/gc) {
            if ($1 eq ']') {
                return (0, \@res);
            } elsif ($1 eq ',') {
                next;
            }
        }
        return 1;
    }
}
# returns a hash, and advances to the character after } (or EOL)
sub parse_object {
    my %res;
    if ($parser_input =~ m/\G}/gc) {
        return (0, \%res);
    }
    while (1) {
        if ($parser_input =~ m/\G([^=]+)=/gc) {
            my $key = $1;
            my ($err, $val) = parse_value();
            if ($err) { 
                return 1; 
            }
            $res{$key} = $val;

            if ($parser_input =~ m/\G(,|}|\s*$)/gc) {
                if ($1 eq ',') {
                    next;
                } else {
                    return (0, \%res);
                } 
            }
        }
        return 1;
    }
}
# returns a scalar, and advances to the character after "
sub parse_string {
    my $res;
    while (1) {
        # copy up to \ or "
        if ($parser_input =~ m/\G([^\\"]*)([\\"])/gc) {
            $res .= $1;
            if ($2 eq '\\') {
                $parser_input =~ m/\G(.)/gc;
                if ($1 eq "n") { 
                    $res .= "\n";
                } else {
                    $res .= $1;
                }
            } elsif ($2 eq '"'){
                return (0, $res);
            }
        } else {
            print("parse 6\n"); return 1;
        }
    }
}
sub parse_line {
    $parser_input = '';
    $parser_input = shift;
    return parse_object();
}

my $connected = 0;
my $printing = 0;
my $print_value = "";

while(my $input = <STDIN>) {
    if (!$connected) {
        $connected = 1;
        #open(my $fh, '>', "${tmpdir}/input_pipe") or die;
        #print($fh, "-gdb-set mi-async on\n");
        #print($fh, "-break-list\n");
        #print($fh, "-stack-info-frame\n");
        #close($fh);
    }
    if ($input =~ /^\*running/) {
        send_to_kak('gdb-handle-running');
    } elsif ($input =~ /^\*stopped,(.*)$/) {
        my ($err, $obj_ref) = parse_line($1);
        if ($err) { print("1\n"); next; }
        my $reason = $$obj_ref{"reason"};
        if (defined($reason) and ($reason eq "exited" or $reason eq "exited-normally" or $reason eq "exited-signalled")) {
            print("2\n"); next;
        }
        my $frame = $$obj_ref{"frame"};
        my $line = $$frame{"line"};
        my $file = $$frame{"fullname"};
        if (defined($line) and defined($file)) {
            send_to_kak('gdb-handle-stopped', $line, escape($file));
        } else {
            send_to_kak('gdb-handle-stopped-unknown');
        }
    } elsif ($input =~ /^=thread-group-exited/) {
        send_to_kak('gdb-handle-exited')
    } elsif ($input =~ /\^done,(frame=.*)$/) {
        my ($err, $obj_ref) = parse_line($1);
        if ($err) { print("3\n"); next; }
        my $line = $$obj_ref{"line"};
        my $file = $$obj_ref{"fullname"};
        if (!defined($line) or !defined($file)) { print("4\n"); next; }
        send_to_kak('gdb-clear-location', ';', 'gdb-handle-stopped', $line, escape($file));
    } elsif ($input =~ /\^done,stack=(.*)$/) {
        #TODO
    } elsif ($input =~ /^=breakpoint-(created|modified),(.*)$/) {
        my $operation = $1;
        # stupid bug: implicit array
        my $fixed = ($2 =~ s/^(bkpt=)(.*)$/$1\[$2\]/r);
        my ($err, $obj_ref) = parse_line($fixed);
        if ($err) { print("5\n"); next; }
        my $bkpts = $$obj_ref{"bkpt"};
        my ($id, $enabled, $line, $file);
        for my $bkpt (@$bkpts) {
            if (!defined($id)     ) { $id      = $$bkpt{"number"}; }
            if (!defined($enabled)) { $enabled = $$bkpt{"enabled"}; }
            if (!defined($line)   ) { $line    = $$bkpt{"line"}; }
            if (!defined($file)   ) { $file    = $$bkpt{"fullname"}; }
        }
        if (defined($id) and defined($enabled) and defined($line) and defined($file)) {
            send_to_kak("gdb-handle-breakpoint-${operation}", $id, $enabled, $line, escape($file));
        } else {
            # possibly pending breakpoint, do something?
        }
    } elsif ($input =~ /^=breakpoint-deleted,(.*)$/) {
        my ($err, $obj_ref) = parse_line($1);
        if ($err) { print("9\n"); next; }
        my $id = $$obj_ref{"id"};
        if (!defined($id)) { print("10\n"); next; }
        send_to_kak('gdb-handle-breakpoint-deleted', $id);
    } elsif ($input =~ /\^done,BreakpointTable=(.*)$/) {
        #TODO
    } elsif ($input =~ /^\^error/) {
        my ($err, $msg) = get_value($input, "msg");
        if ($err) { print("11\n"); next; }
        send_to_kak('echo', '-debug', escape($msg));
    } elsif ($input =~ /^&"print (.*?)(\\n)?"$/) {
        $print_value = "$1 == ";
        $printing = 1;
    } elsif ($input =~ /^~"(.*?)(\\n)?"$/) {
        if ($printing) {
            my $append;
            if ($printing == 1) {
                $1 =~ m/\$\d+ = (.*)$/;
                $append = $1;
                $printing = 2;
            } else {
                $append = $1;
            }
            $print_value .= "${append}\n";
        }
    } elsif ($input =~ /\^done/) {
        if ($printing) {
            send_to_kak("gdb-handle-print", escape($print_value));
            $printing = 0;
            $print_value = "";
        }
    }
}

#/\^done,stack=/ {
#    frames_number = split($0, frames, "frame=")
#    for (i = 2; i <= frames_number; i++) {
#        frame = frames[i]
#        file = get(frame, "fullname=\"", "[^\"]*", "\"")
#        line = get(frame, "line=\"", "[0-9]+", "\"")
#        cmd = "awk \"NR==" line "\" \"" file "\""
#        cmd | getline call
#        close(cmd)
#        print(file ":" line ":" call) > "'"$tmpdir/backtrace"'"
#    }
#    close("'"$tmpdir/backtrace"'")
#}
#/\^done,BreakpointTable=/ {
#    command = "gdb-clear-breakpoints"
#    breakpoints_number = split($0, breakpoints, "bkpt=")
#    for (i = 2; i <= breakpoints_number; i++) {
#        command = command "; gdb-handle-breakpoint-created " breakpoint_info(breakpoints[i])
#    }
#    send(command)
#}
