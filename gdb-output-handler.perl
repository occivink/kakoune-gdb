use strict;
use warnings;

my $kak_session = $ENV{"kak_session"};
my $debug = $ENV{"kak_opt_gdb_debug"};
if (defined($debug)) {
    $debug = ($debug eq "true");
} else {
    $debug = 0;
}
my $tmpdir = $ENV{"tmpdir"} || "/tmp";

sub escape {
    my $command = shift;
    if (not defined($command)) { return ''; }
    $command =~ s/'/''/g;
    return "'${command}'";
}

sub send_to_kak {
    my $err = shift;
    if ($err) { return $err; }
    my $command = join(' ', @_);

    if ($kak_session) {
        # what a silly pattern
        my $pid = open(CHILD_STDIN, "|-");
        defined($pid) || die "can't fork: $!";
        $SIG{PIPE} = sub { die "child pipe broke" };
        if ($pid > 0) { # parent
            print CHILD_STDIN $command;
            close(CHILD_STDIN) || return 1;
        } else { # child
            exec("kak", "-p", $kak_session) || die "can't exec program: $!";
        }
    } else {
        # for script debugging purposes
        print("${command}\n");
    }
    return 0;
}

sub pipe_to_buffer {
    my $err = shift;
    if ($err) { return $err; }
    my $buffer_name = shift;
    my $content = shift;
    my $init_command = shift;

    $err = send_to_kak($err, "edit!", "-fifo", "${tmpdir}/helper_pipe", $buffer_name, ";", "evaluate-commands", $init_command);
    open(my $fh, '>', "${tmpdir}/helper_pipe") or die;
    print $fh $content;
    close($fh);
}

# this parser could be made a LOT simpler by operating in a single pass
# but gdb doesn't respect its own grammar so we need to introduce dumb hacks
# they also won't fix it for backwards-compatibility reasons
# even though they have MI-versioning, super lame

# dunno if that's proper use of the word 'tokenize' but good enough
sub tokenize_val {
    my $ref = shift;
    my $closer = shift;
    my $nested_brackets = 0;
    my $nested_braces = 0;
    my $res = "";
    while (1) {
        if ($$ref !~ m/\G([^",\{\}\[\]]*)([",\{\}\[\]])/gc) {
            return 1;
        }

        $res .= $1;
        if (($2 eq ',' or $2 eq $closer) and ($nested_braces == 0 and $nested_brackets == 0)) {
            return (0, $res, $2);
        }
        $res .= $2;

        if ($2 eq '"') {
            # advance til end of string, because it may contain brackets, braces or commas
            while (1) {
                if ($$ref !~ m/\G([^\\"]*([\\"]))/gc) { return 1; }
                $res .= $1;
                if ($2 eq '"') {
                    last;
                }
                # it's a \, absorb the escaped character
                if ($$ref !~ m/\G(.)/gc) { return 1; }
                $res .= $1;
            }
        } elsif ($2 eq '{') {
            $nested_braces += 1;
        } elsif ($2 eq '}') {
            if ($nested_braces == 0) { return 1; }
            $nested_braces -= 1;
        } elsif ($2 eq '[') {
            $nested_brackets += 1;
        } elsif ($2 eq ']') {
            if ($nested_brackets == 0) { return 1; }
            $nested_brackets -= 1;
        }
    }
}

sub parse_string {
    my $prev_err = shift;
    if ($prev_err) { return $prev_err; }
    my $input = shift;
    if (not defined($input)) { return 1; }
    if ($input !~ m/\G"/gc) {
        return 1;
    }
    my $res;
    while (1) {
        # copy up to \ or "
        if ($input !~ m/\G([^\\"]*)([\\"])/gc) {
            return 1;
        }
        $res .= $1;
        if ($2 eq '\\') {
            $input =~ m/\G(.)/gc;
            if ($1 eq "n") {
                $res .= "\n";
            } else {
                $res .= $1;
            }
        } elsif ($2 eq '"'){
            return (0, $res);
        }
    }
}

sub parse_array {
    my $prev_err = shift;
    if ($prev_err) { return $prev_err; }
    my $input = shift;
    if (not defined($input)) { return 1; }
    if ($input !~ m/\G\[/gc) {
        return 1;
    }
    my @res;
    if ($input =~ m/\G]/gc) {
        return (0, @res);
    }
    while (1) {
        my ($err, $val, $separator) = tokenize_val(\$input, ']');
        if ($err) { return 1; }
        push(@res, $val);
        if ($separator eq ']') {
            return (0, @res);
        }
    }
    return 1;
}

sub parse_map {
    my $prev_err = shift;
    if ($prev_err) { return $prev_err; }
    my $input = shift;
    if (not defined($input)) { return 1; }
    if ($input !~ m/\G\{/gc) {
        return 1;
    }
    my %res;
    if ($input =~ m/\G}/gc) {
        return (0, %res);
    }
    while (1) {
        if ($input !~ m/\G([A-Za-z_-]+)=/gc) {
            return 1;
        }
        my $key = $1;
        my ($err, $val, $separator) = tokenize_val(\$input, '}');
        if ($err) { return 1; }
        $res{$key} = $val;
        if ($separator eq '}') {
            return (0, %res);
        }
    }
}

sub breakpoint_to_command {
    my $err = shift;
    if ($err) { return $err; }

    my $cmd = shift;
    my $map = shift;
    my (%bkpt, $id, $enabled, $line, $file, $addr);
    ($err, %bkpt) = parse_map($err, $map);
    ($err, $id) = parse_string($err, $bkpt{"number"});
    ($err, $enabled) = parse_string($err, $bkpt{"enabled"});

    my $is_multiple = 0;
    if (exists($bkpt{"addr"})) {
        ($err, $addr) = parse_string($err, $bkpt{"addr"});
        if ($addr eq "<PENDING>") {
            return (0, ());
        } elsif ($addr eq "<MULTIPLE>") {
             $is_multiple = 1;
             my @bkpt_locations;
             ($err, @bkpt_locations) = parse_array($err, $bkpt{"locations"});
             my $i = 1;
             while ($i < scalar(@bkpt_locations)) {
                my %sub_bkpt;
                ($err, %sub_bkpt) = parse_map($err, $bkpt_locations[$i]);
                if (exists($sub_bkpt{"line"}) and exists($sub_bkpt{"fullname"})) {
                    ($err, $line) = parse_string($err, $sub_bkpt{"line"});
                    ($err, $file) = parse_string($err, $sub_bkpt{"fullname"});

                    if ($err) { return $err; }
                    return (0, ($cmd, $id, $enabled, $line, escape($file)));
                }
                $i += 1;
             }
        }
    }
    if (not $is_multiple) {
        ($err, $line) = parse_string($err, $bkpt{"line"});
        ($err, $file) = parse_string($err, $bkpt{"fullname"});
        if ($err) { return $err; }
        return (0, ($cmd, $id, $enabled, $line, escape($file)));
    }
    return 1;
}

sub get_line_file {
    my $number = shift;
    my $file = shift;
    open(my $fh, '<', $file) or return 1;
    while (my $line = <$fh>) {
        if ($. == $number) {
            close($fh);
            $line =~ s/\n$//;
            return (0, $line);
        }
    }
    close($fh);
    return 1;
}

my $connected = 0;

while (my $input = <STDIN>) {
    # remove crlf and other bs
    $input =~ s/\s+\z//;
    my $err = 0;
    if (!$connected) {
        $connected = 1;
        if ($kak_session) {
            open(my $fh, '>', "${tmpdir}/input_pipe") or die;
            print $fh "-break-list\n";
            print $fh "-stack-info-frame\n";
            close($fh);
        }
    }
    if ($debug) {
        send_to_kak($err, "echo", "-debug", "[gdb][perl]", escape($input));
    }
    if ($input =~ /^\*running/) {
        $err = send_to_kak($err, 'gdb-handle-running');
    } elsif ($input =~ /^\*stopped,(.*)$/) {
        my (%map, $reason, %frame, $line, $file, $skip);
        ($err, %map) = parse_map($err, '{' . $1 . '}');
        $skip = 0;
        if (exists($map{"reason"})) {
            ($err, $reason) = parse_string($err, $map{"reason"});
            if ($reason eq "exited" or $reason eq "exited-normally" or $reason eq "exited-signalled") {
                $skip = 1;
            }
        }
        if (not $skip) {
            ($err, %frame) = parse_map($err, $map{"frame"});
            if (exists($frame{"line"}) and exists($frame{"fullname"})) {
                ($err, $line) = parse_string($err, $frame{"line"});
                ($err, $file) = parse_string($err, $frame{"fullname"});
                $err = send_to_kak($err, 'gdb-handle-stopped', $line, escape($file));
            } else {
                $err = send_to_kak($err, 'gdb-handle-stopped-unknown');
            }
        }
    } elsif ($input =~ /^=thread-group-exited/) {
        $err = send_to_kak($err, 'gdb-handle-exited');
    } elsif ($input =~ /\^done,frame=(.*)$/) {
        my (%map, $line, $file);
        ($err, %map) = parse_map($err, $1);
        ($err, $line) = parse_string($err, $map{"line"});
        ($err, $file) = parse_string($err, $map{"fullname"});
        $err = send_to_kak($err, 'gdb-clear-location', ';', 'gdb-handle-stopped', $line, escape($file));
    } elsif ($input =~ /^=thread-selected,(.*)$/) {
        my (%map, %frame, $file, $line);
        ($err, %map) = parse_map($err, '{' . $1 . '}');
        ($err, %frame) = parse_map($err, $map{"frame"});
        ($err, $line) = parse_string($err, $frame{"line"});
        ($err, $file) = parse_string($err, $frame{"fullname"});
        $err = send_to_kak($err, 'gdb-clear-location', ';', 'gdb-handle-stopped', $line, escape($file));
    } elsif ($input =~ /\^done,stack=(.*)$/) {
        my @array;
        ($err, @array) = parse_array($err, $1);
        open(my $fifo, ">>", "${tmpdir}/backtrace") or next;
        for my $val (@array) {
            $val =~ s/^frame=//;
            my $line = "???";
            my $file = "???";
            my $content = "???";
            my %frame;
            ($err, %frame) = parse_map($err, $val);
            if (exists($frame{"line"})) {
                ($err, $line) = parse_string($err, $frame{"line"});
            }
            if (exists($frame{"fullname"})) {
                ($err, $file) = parse_string($err, $frame{"fullname"});
            }
            if ($line ne "???" and $file ne "???") {
                my ($err_get_line, $found_content) = get_line_file($line, $file);
                if (not $err_get_line) { $content = $found_content; }
            }
            print $fifo "$file:$line:$content\n";
        }
        close($fifo);
    } elsif ($input =~ /^=breakpoint-(created|modified),bkpt=(.*)$/) {
        my ($operation, @command);
        $operation = $1;
        # implicit array, add delimiters manually
        ($err, @command) = breakpoint_to_command($err, "gdb-handle-breakpoint-$operation", $2);

        if (scalar(@command) > 0) {
            $err = send_to_kak($err, @command);
        }
    } elsif ($input =~ /^=breakpoint-deleted,(.*)$/) {
        my (%map, $id);
        ($err, %map) = parse_map($err, '{' . $1 . '}');
        ($err, $id)  = parse_string($err, $map{"id"});
        $err = send_to_kak($err, 'gdb-handle-breakpoint-deleted', $id);
    } elsif ($input =~ /\^done,BreakpointTable=(.*)$/) {
        my (%map, @body, @command, @subcommand);
        ($err, %map) = parse_map($err, $1);
        ($err, @body) = parse_array($err, $map{"body"});
        @command = ('gdb-clear-breakpoints');
        for my $val (@body) {
            # get rid of the bkpt= part in bkpt={...}
            # what's the point of using keys in an array, if they're always the same?
            if ($val !~ m/^bkpt=(.*)$/) { $err = 1; }
            $val = $1;
            ($err, @subcommand) = breakpoint_to_command($err, 'gdb-handle-breakpoint-created', $val);
            if (scalar(@subcommand) > 0) {
                push(@command, ';');
                push(@command, @subcommand);
            }
        }
        $err = send_to_kak($err, @command);
    } elsif ($input =~ /^\^error,msg=(.*)$/) {
        my $msg;
        ($err, $msg) = parse_string($err, $1);
        $err = send_to_kak($err, "echo", "-debug", "[gdb][error]", escape($msg));
    } elsif ($input =~ /^\^done,value=(.*)$/) {
        my $val;
        ($err, $val) = parse_string($err, $1);
        $err = send_to_kak($err, "gdb-handle-print", escape($val));
    } elsif ($input =~ /^\^done,asm_insns=(.*)$/) {
        my (@insns, $disassembly);
        ($err, @insns) = parse_array($err, $1);
        for my $insn (@insns) {
            my (%map, $inst, $addr, $func, $offset, $line);
            ($err, %map) = parse_map($err, $insn);
            ($err, $inst) = parse_string($err, $map{"inst"});
            ($err, $addr) = parse_string($err, $map{"address"});
            ($err, $func) = parse_string($err, $map{"func-name"});
            ($err, $offset) = parse_string($err, $map{"offset"});
            $line = sprintf("%s +%-6s %s\n", $addr, $offset, $inst);
            if (!$disassembly) {
                $disassembly = "disassembly of function $func\n"
            }
            $disassembly = $disassembly . $line
        }
        $err = pipe_to_buffer($err, "*gdb-disassembly*", $disassembly, "set-option buffer filetype gas")
    }
    if ($err) {
        send_to_kak(0, "echo", "-debug", "[kakoune-gdb]", escape("Internal error handling this output: $input"));
    }
}
