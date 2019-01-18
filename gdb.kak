# override to allow starting wrapper scripts
# they must be compatible with gdb arguments
decl str gdb_program "gdb"

# script summary:
# a long running shell process starts a gdb session (or connects to an existing one) and handles input/output
# kakoune -> gdb communication is done by writing the gdb commands to a fifo
# gdb -> kakoune communication is done by a perl process that translates gdb events into kakoune commands
# the gdb-handle-* commands act upon gdb notifications to update the kakoune state

decl str gdb_breakpoint_active_symbol "●"
decl str gdb_breakpoint_inactive_symbol "○"
decl str gdb_location_symbol "➡"

face global GdbBreakpoint red,default
face global GdbLocation blue,default

# a debugging session has been started
decl bool gdb_started false
# the debugged program is currently running (stopped or not)
decl bool gdb_program_running false
# the debugged program is currently running, but stopped
decl bool gdb_program_stopped false
# if not empty, contains the name of client in which the autojump is performed
decl str gdb_autojump_client
# if not empty, contains the name of client in which the value is printed
# set by default to the client which started the session
decl str gdb_print_client

# contains all known breakpoints in this format:
# id enabled line file id enabled line file  ...
decl str-list gdb_breakpoints_info
# if execution is currently stopped, contains the location in this format:
# line file
decl str-list gdb_location_info
# note that these variables may reference locations that are not in currently opened buffers

# list of pending commands that will be executed the next time the process is stopped
decl -hidden str gdb_pending_commands

# a visual indicator showing the current state of the script
decl str gdb_indicator

# the directory containing the input fifo, pty object and backtrace
decl -hidden str gdb_dir

# corresponding flags generated from the previous variables
# these are only set on buffer scope
decl -hidden line-specs gdb_breakpoints_flags
decl -hidden line-specs gdb_location_flag

addhl shared/gdb group -passes move
addhl shared/gdb/ flag-lines GdbLocation gdb_location_flag
addhl shared/gdb/ flag-lines GdbBreakpoint gdb_breakpoints_flags

def -params .. -file-completion gdb-session-new %{
    gdb-session-connect-internal
    nop %sh{
        # can't connect until socat has created the pty thing
        while [ ! -e "${kak_opt_gdb_dir}/pty" ]; do
            sleep 0.1
        done
    }
    terminal %opt{gdb_program} %arg{@} --init-eval-command "set mi-async on" --init-eval-command "new-ui mi3 %opt{gdb_dir}/pty"
}

def rr-session-new %{
    gdb-session-connect-internal
    nop %sh{
        while [ ! -e "${kak_opt_gdb_dir}/pty" ]; do
            sleep 0.1
        done
    }
    terminal rr replay -o --init-eval-command "set mi-async on" --init-eval-command "new-ui mi3 %opt{gdb_dir}/pty"
}

def gdb-session-connect %{
    gdb-session-connect-internal
    info "Please instruct gdb to ""new-ui mi3 %opt{gdb_dir}/pty"""
}

def -hidden gdb-session-connect-internal %§
    try %{
        # a previous session was ongoing, stop it and clean the options
        gdb-session-stop
        set global gdb_started false
        set global gdb_program_running false
        set global gdb_program_stopped false
        set global gdb_indicator ""
        set global gdb_dir ""

        set global gdb_breakpoints_info
        set global gdb_location_info
        eval -buffer * %{
            unset buffer gdb_location_flag
            unset buffer gdb_breakpoint_flags
        }
        rmhl global/gdb-ref
        rmhooks global gdb-ref
    }
    eval %sh§§
        if ! command -v socat >/dev/null 2>&1 || ! command -v perl >/dev/null 2>&1; then
            printf "fail '''socat'' and ''perl'' must be installed to use this plugin'"
            exit
        fi
        export tmpdir=$(mktemp --tmpdir -d gdb_kak_XXX)
        mkfifo "${tmpdir}/input_pipe"
        {
            # too bad gdb only exposes its new-ui via a pty, instead of simply a socket
            # the 'wait-slave' argument makes socat exit when the other end of the pty (gdb) exits, which is exactly what we want
            # 'setsid socat' allows us to ignore any ctrl+c sent from kakoune
            tail -n +1 -f "${tmpdir}/input_pipe" | setsid socat "pty,wait-slave,link=${tmpdir}/pty" STDIO,nonblock=1 | perl -e '
use strict;
use warnings;
my $session = $ENV{"kak_session"};
my $tmpdir = $ENV{"tmpdir"};
sub escape {
    my $command = shift;
    if (not defined($command)) { return '\'''\''; }
    $command =~ s/'\''/'\'''\''/g;
    return "'\''${command}'\''";
}
sub send_to_kak {
    my $err = shift;
    if ($err) { return $err; }
    my $command = join('\'' '\'', @_);
    my $pid = open(CHILD_STDIN, "|-");
    defined($pid) || die "can'\''t fork: $!";
    $SIG{PIPE} = sub { die "child pipe broke" };
    if ($pid > 0) { # parent
        print CHILD_STDIN $command;
        close(CHILD_STDIN) || return 1;
    } else { # child
        exec("kak", "-p", $session) || die "can'\''t exec program: $!";
    }
    return 0;
}
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
        if (($2 eq '\'','\'' or $2 eq $closer) and ($nested_braces == 0 and $nested_brackets == 0)) {
            return (0, $res, $2);
        }
        $res .= $2;
        if ($2 eq '\''"'\'') {
            while (1) {
                if ($$ref !~ m/\G([^\\"]*([\\"]))/gc) { return 1; }
                $res .= $1;
                if ($2 eq '\''"'\'') {
                    last;
                }
                if ($$ref !~ m/\G(.)/gc) { return 1; }
                $res .= $1;
            }
        } elsif ($2 eq '\''{'\'') {
            $nested_braces += 1;
        } elsif ($2 eq '\''}'\'') {
            if ($nested_braces == 0) { return 1; }
            $nested_braces -= 1;
        } elsif ($2 eq '\''['\'') {
            $nested_brackets += 1;
        } elsif ($2 eq '\'']'\'') {
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
        if ($input !~ m/\G([^\\"]*)([\\"])/gc) {
            return 1;
        }
        $res .= $1;
        if ($2 eq '\''\\'\'') {
            $input =~ m/\G(.)/gc;
            if ($1 eq "n") {
                $res .= "\n";
            } else {
                $res .= $1;
            }
        } elsif ($2 eq '\''"'\''){
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
        my ($err, $val, $separator) = tokenize_val(\$input, '\'']'\'');
        if ($err) { return 1; }
        push(@res, $val);
        if ($separator eq '\'']'\'') {
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
        my ($err, $val, $separator) = tokenize_val(\$input, '\''}'\'');
        if ($err) { return 1; }
        $res{$key} = $val;
        if ($separator eq '\''}'\'') {
            return (0, %res);
        }
    }
}
sub fixup_breakpoint_table {
    my $err = shift;
    if ($err) { return $err; }
    my @table = @_;
    my @fixed;
    my $index = 0;
    while ($index < scalar(@table)) {
        my $val = $table[$index];
        if ($val !~ m/^bkpt=(.*)$/) { return 1; }
        my $res = '\''['\'' . $1;
        $index += 1;
        while ($index < scalar(@table)) {
            my $sub = $table[$index];
            if ($sub =~ m/^bkpt=/) { last; }
            $res .= '\'','\'' . $sub;
            $index += 1;
        }
        $res .= '\'']'\'';
        push(@fixed, $res);
    }
    return (0, @fixed);
}
sub breakpoint_to_command {
    my $err = shift;
    if ($err) { return $err; }
    my $cmd = shift;
    my $array = shift;
    my (@bkpt_array, %main_bkpt, $id, $enabled, $line, $file, $addr);
    ($err, @bkpt_array) = parse_array($err, $array);
    ($err, %main_bkpt) = parse_map($err, $bkpt_array[0]);
    ($err, $id) = parse_string($err, $main_bkpt{"number"});
    ($err, $enabled) = parse_string($err, $main_bkpt{"enabled"});
    my $is_multiple = 0;
    if (exists($main_bkpt{"addr"})) {
        ($err, $addr) = parse_string($err, $main_bkpt{"addr"});
        if ($addr eq "<PENDING>") {
            return (0, ());
        } elsif ($addr eq "<MULTIPLE>") {
             $is_multiple = 1;
             my $i = 1;
             while ($i < scalar(@bkpt_array)) {
                my %sub_bkpt;
                ($err, %sub_bkpt) = parse_map($err, $bkpt_array[$i]);
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
        ($err, $line) = parse_string($err, $main_bkpt{"line"});
        ($err, $file) = parse_string($err, $main_bkpt{"fullname"});
        if ($err) { return $err; }
        return (0, ($cmd, $id, $enabled, $line, escape($file)));
    }
    return 1;
}
sub get_line_file {
    my $number = shift;
    my $file = shift;
    open(my $fh, '\''<'\'', $file) or return 1;
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
    $input =~ s/\s+\z//;
    my $err = 0;
    if (!$connected) {
        $connected = 1;
        open(my $fh, '\''>'\'', "${tmpdir}/input_pipe") or die;
        print $fh "-break-list\n";
        print $fh "-stack-info-frame\n";
        close($fh);
    }
    if ($input =~ /^\*running/) {
        $err = send_to_kak($err, '\''gdb-handle-running'\'');
    } elsif ($input =~ /^\*stopped,(.*)$/) {
        my (%map, $reason, %frame, $line, $file, $skip);
        ($err, %map) = parse_map($err, '\''{'\'' . $1 . '\''}'\'');
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
                $err = send_to_kak($err, '\''gdb-handle-stopped'\'', $line, escape($file));
            } else {
                $err = send_to_kak($err, '\''gdb-handle-stopped-unknown'\'');
            }
        }
    } elsif ($input =~ /^=thread-group-exited/) {
        $err = send_to_kak($err, '\''gdb-handle-exited'\'');
    } elsif ($input =~ /\^done,frame=(.*)$/) {
        my (%map, $line, $file);
        ($err, %map) = parse_map($err, $1);
        ($err, $line) = parse_string($err, $map{"line"});
        ($err, $file) = parse_string($err, $map{"fullname"});
        $err = send_to_kak($err, '\''gdb-clear-location'\'', '\'';'\'', '\''gdb-handle-stopped'\'', $line, escape($file));
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
        ($err, @command) = breakpoint_to_command($err, "gdb-handle-breakpoint-$operation", '\''['\'' . $2 . '\'']'\'');
        if (scalar(@command) > 0) {
            $err = send_to_kak($err, @command);
        }
    } elsif ($input =~ /^=breakpoint-deleted,(.*)$/) {
        my (%map, $id);
        ($err, %map) = parse_map($err, '\''{'\'' . $1 . '\''}'\'');
        ($err, $id)  = parse_string($err, $map{"id"});
        $err = send_to_kak($err, '\''gdb-handle-breakpoint-deleted'\'', $id);
    } elsif ($input =~ /\^done,BreakpointTable=(.*)$/) {
        my (%map, @body, @body_fixed, @command, @subcommand);
        ($err, %map) = parse_map($err, $1);
        ($err, @body) = parse_array($err, $map{"body"});
        ($err, @body_fixed) = fixup_breakpoint_table($err, @body);
        @command = ('\''gdb-clear-breakpoints'\'');
        for my $val (@body_fixed) {
            ($err, @subcommand) = breakpoint_to_command($err, '\''gdb-handle-breakpoint-created'\'', $val);
            if (scalar(@subcommand) > 0) {
                push(@command, '\'';'\'');
                push(@command, @subcommand);
            }
        }
        $err = send_to_kak($err, @command);
    } elsif ($input =~ /^\^error,msg=(.*)$/) {
        my $msg;
        ($err, $msg) = parse_string($err, $1);
        $err = send_to_kak($err, "echo", "-debug", "[gdb]", escape($msg));
    } elsif ($input =~ /^\^done,value=(.*)$/){
        my $val;
        ($err, $val) = parse_string($err, $1);
        $err = send_to_kak($err, "gdb-handle-print", escape($val));
    }
    if ($err) {
        send_to_kak(0, "echo", "-debug", "[kakoune-gdb]", escape("Internal error handling this output: $input"));
    }
}
'
            # when the perl program finishes (crashed or gdb closed the pty), cleanup and tell kakoune to stop the session
            rm -f "${tmpdir}/input_pipe"
            rmdir "$tmpdir"
            printf "gdb-handle-perl-exited '%s'" "${tmpdir}" | kak -p $kak_session
        } > /dev/null 2>&1 < /dev/null &
        printf "set global gdb_dir '%s'\n" "$tmpdir"
        # put an empty flag of the same width to prevent the columns from jiggling
        # TODO: support double-width characters (?)
        location_len=$(printf %s "$kak_opt_gdb_location_symbol" | wc -m)
        break_len=$(printf %s "$kak_opt_gdb_breakpoint_active_symbol" | wc -m)
        printf "set global gdb_location_flag 0 '0|%${location_len}s'\n"
        printf "set global gdb_breakpoints_flags 0 '0|%${break_len}s'\n"
    §§
    set global gdb_started true
    set global gdb_print_client %val{client}
    gdb-set-indicator-from-current-state
    hook -group gdb global BufOpenFile .* %{
        gdb-refresh-location-flag %val{buffile}
        gdb-refresh-breakpoints-flags %val{buffile}
    }
    hook -group gdb global KakEnd .* %{
        gdb-session-stop
    }
    addhl global/gdb-ref ref -passes move gdb
§

def gdb-jump-to-location %{
    try %{ eval %sh{
        eval set -- "$kak_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        line="$1"
        buffer="$2"
        printf "edit -existing '%s' %s; exec gi" "$buffer" "$line"
    }}
}

def -params 1 gdb-cmd %{
    eval %sh{
        if [ "$kak_opt_gdb_started" = false ] || [ ! -p "$kak_opt_gdb_dir"/input_pipe ]; then
            printf "fail 'This command must be executed in a gdb session'"
            exit
        fi
        printf %s\\n "$1"  > "$kak_opt_gdb_dir"/input_pipe
    }
}

def gdb-session-stop      %{ gdb-cmd "-gdb-exit" }
def gdb-run -params ..    %{ gdb-cmd "-exec-arguments %arg{@}
-exec-run" }
def gdb-start -params ..  %{ gdb-cmd "-exec-arguments %arg{@}
-exec-run --start" }
def gdb-step              %{ gdb-cmd "-exec-step" }
def gdb-next              %{ gdb-cmd "-exec-next" }
def gdb-finish            %{ gdb-cmd "-exec-finish" }
def gdb-continue          %{ gdb-cmd "-exec-continue" }
def gdb-set-breakpoint    %{ gdb-breakpoint-impl false true }
def gdb-clear-breakpoint  %{ gdb-breakpoint-impl true false }
def gdb-toggle-breakpoint %{ gdb-breakpoint-impl true true }
def gdb-continue-or-run %{
   %sh{
      if [ "$kak_opt_gdb_program_running" = true ]; then
         printf "gdb-continue\n"
      else
         printf "gdb-run\n"
      fi
   }
}

# gdb doesn't tell us in its output what was the expression we asked for, so keep it internally for printing later
decl -hidden str gdb_expression_demanded

def gdb-print -params ..1 %{
    try %{
        eval %sh{ [ -z "$1" ] && printf fail }
        set global gdb_expression_demanded %arg{1}
    } catch %{
        set global gdb_expression_demanded %val{selection}
    }
    gdb-cmd "-data-evaluate-expression '%opt{gdb_expression_demanded}'"
}

def gdb-enable-autojump %{
    try %{
        eval %sh{ [ "$kak_opt_gdb_started" = false ] && printf fail }
        set global gdb_autojump_client %val{client}
        gdb-set-indicator-from-current-state
    }
}
def gdb-disable-autojump %{
    set global gdb_autojump_client ""
    gdb-set-indicator-from-current-state
}
def gdb-toggle-autojump %{
    try %{
        eval %sh{ [ -z "$kak_opt_gdb_autojump_client" ] && printf fail }
        gdb-disable-autojump
    } catch %{
        gdb-enable-autojump
    }
}

decl -hidden int backtrace_current_line

def gdb-backtrace %{
    try %{
        try %{ db *gdb-backtrace* }
        eval %sh{
            [ "$kak_opt_gdb_stopped" = false ] && printf fail
            mkfifo "$kak_opt_gdb_dir"/backtrace
        }
        gdb-cmd '-stack-list-frames'
        eval -try-client %opt{toolsclient} %{
            edit! -fifo "%opt{gdb_dir}/backtrace" *gdb-backtrace*
            set buffer backtrace_current_line 0
            addhl buffer/ regex "^([^\n]*?):(\d+)" 1:cyan 2:green
            addhl buffer/ line '%opt{backtrace_current_line}' default+b
            map buffer normal <ret> ': gdb-backtrace-jump<ret>'
            hook -always -once buffer BufCloseFifo .* %{
                nop %sh{ rm -f "$kak_opt_gdb_dir"/backtrace }
            }
        }
    }
}

def -hidden gdb-backtrace-jump %{
    eval -save-regs '/' %{
        try %{
            exec -save-regs '' 'xs^([^:]+):(\d+)<ret>'
            set buffer backtrace_current_line %val{cursor_line}
            eval -try-client %opt{jumpclient} "edit -existing %reg{1} %reg{2}"
            try %{ focus %opt{jumpclient} }
        }
    }
}

def gdb-backtrace-up %{
    eval -try-client %opt{jumpclient} %{
        buffer *gdb-backtrace*
        exec "%opt{backtrace_current_line}gk<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

def gdb-backtrace-down %{
    eval -try-client %opt{jumpclient} %{
        buffer *gdb-backtrace*
        exec "%opt{backtrace_current_line}gj<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

# implementation details

def -hidden gdb-set-indicator-from-current-state %{
    set global gdb_indicator %sh{
        [ "$kak_opt_gdb_started" = false ] && exit
        printf 'gdb '
        a=$(
            [ "$kak_opt_gdb_program_running" = true ] && printf '[running]'
            [ "$kak_opt_gdb_program_stopped" = true ] && printf '[stopped]'
            [ -n "$kak_opt_gdb_autojump_client" ] && printf '[autojump]'
        )
        [ -n "$a" ] && printf "$a "
    }
}

# the two params are bool that indicate the following
# if %arg{1} == true, existing breakpoints where there is a cursor are cleared (untouched otherwise)
# if %arg{2} == true, new breakpoints are set where there is a cursor and no breakpoint (not created otherwise)
def gdb-breakpoint-impl -hidden -params 2 %{
    eval -draft %{
        # reduce to cursors so that we can just extract the line out of selections_desc without any hassle
        exec 'gh'
        eval %sh{
            [ "$kak_opt_gdb_started" = false ] && exit
            delete="$1"
            create="$2"
            commands=$(
                # iterating with space-splitting is safe because it's not arbitrary input
                # lucky me
                for selection in $kak_selections_desc; do
                    cursor_line=${selection%%.*}
                    match_found="false"
                    eval set -- "$kak_opt_gdb_breakpoints_info"
                    while [ $# -ne 0 ]; do
                        if [ "$4" = "$kak_buffile" ] && [ "$3" = "$cursor_line" ]; then
                            [ "$delete" = true ] && printf "delete %s\n" "$1"
                            match_found="true"
                        fi
                        shift 4
                    done
                    if [ "$match_found" = false ] && [ "$create" = true ]; then
                        printf "break %s:%s\n" "$kak_buffile" "$cursor_line"
                    fi
                done
            )
            if [ "$kak_opt_gdb_program_running" = false ] ||
                [ "$kak_opt_gdb_program_stopped" = true ]
            then
                printf "%s\n" "$commands" > "$kak_opt_gdb_dir"/input_pipe
            else
                printf "set global gdb_pending_commands '%s'" "$commands"
                # STOP!
                # breakpoint time
                echo "-exec-interrupt" > "$kak_opt_gdb_dir"/input_pipe
            fi
        }
    }
}


def -hidden -params 2 gdb-handle-stopped %{
    try %{
        gdb-process-pending-commands
        gdb-continue
    } catch %{
        set global gdb_program_stopped true
        gdb-set-indicator-from-current-state
        set global gdb_location_info  %arg{1} %arg{2}
        gdb-refresh-location-flag %arg{2}
        try %{ eval -client %opt{gdb_autojump_client} gdb-jump-to-location }
    }
}

def -hidden gdb-handle-stopped-unknown %{
    try %{
        gdb-process-pending-commands
        gdb-continue
    } catch %{
        set global gdb_program_stopped true
        gdb-set-indicator-from-current-state
    }
}

def -hidden gdb-handle-exited %{
    try %{ gdb-process-pending-commands }
    set global gdb_program_running false
    set global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

def -hidden gdb-process-pending-commands %{
    eval %sh{
        if [ ! -n "$kak_opt_gdb_pending_commands" ]; then
            printf fail
            exit
        fi
        printf "%s\n" "$kak_opt_gdb_pending_commands" > "$kak_opt_gdb_dir"/input_pipe
    }
    set global gdb_pending_commands ""
}

def -hidden gdb-handle-running %{
    set global gdb_program_running true
    set global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

def -hidden gdb-clear-location %{
    try %{ eval %sh{
        eval set -- "$kak_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        buffer="$2"
        printf "unset 'buffer=%s' gdb_location_flag" "$buffer"
    }}
    set global gdb_location_info
}

# refresh the location flag of the buffer passed as argument
def -hidden -params 1 gdb-refresh-location-flag %{
    # buffer may not exist, only try
    try %{
        eval -buffer %arg{1} %{
            eval %sh{
                buffer_to_refresh="$1"
                eval set -- "$kak_opt_gdb_location_info"
                [ $# -eq 0 ] && exit
                buffer_stopped="$2"
                [ "$buffer_to_refresh" != "$buffer_stopped" ] && exit
                line_stopped="$1"
                printf "set -add buffer gdb_location_flag '%s|%s'" "$line_stopped" "$kak_opt_gdb_location_symbol"
            }
        }
    }
}

def -hidden -params 4 gdb-handle-breakpoint-created %{
    set -add global gdb_breakpoints_info %arg{1} %arg{2} %arg{3} %arg{4}
    gdb-refresh-breakpoints-flags %arg{4}
}

def -hidden -params 1 gdb-handle-breakpoint-deleted %{
    eval %sh{
        id_to_delete="$1"
        printf "set global gdb_breakpoints_info\n"
        eval set -- "$kak_opt_gdb_breakpoints_info"
        while [ $# -ne 0 ]; do
            if [ "$1" = "$id_to_delete" ]; then
                buffer_deleted_from="$4"
            else
                printf "set -add global gdb_breakpoints_info %s %s %s '%s'\n" "$1" "$2" "$3" "$4"
            fi
            shift 4
        done
        printf "gdb-refresh-breakpoints-flags '%s'\n" "$buffer_deleted_from"
    }
}

def -hidden -params 4 gdb-handle-breakpoint-modified %{
    eval %sh{
        id_modified="$1"
        active="$2"
        line="$3"
        file="$4"
        printf "set global gdb_breakpoints_info\n"
        eval set -- "$kak_opt_gdb_breakpoints_info"
        while [ $# -ne 0 ]; do
            if [ "$1" = "$id_modified" ]; then
                printf "set -add global gdb_breakpoints_info %s %s %s '%s'\n" "$id_modified" "$active" "$line" "$file"
            else
                printf "set -add global gdb_breakpoints_info %s %s %s '%s'\n" "$1" "$2" "$3" "$4"
            fi
            shift 4
        done
    }
    gdb-refresh-breakpoints-flags %arg{4}
}

# refresh the breakpoint flags of the file passed as argument
def -hidden -params 1 gdb-refresh-breakpoints-flags %{
    # buffer may not exist, so only try
    try %{
        eval -buffer %arg{1} %{
            unset buffer gdb_breakpoints_flags
            eval %sh{
                to_refresh="$1"
                eval set -- "$kak_opt_gdb_breakpoints_info"
                while [ $# -ne 0 ]; do
                    buffer="$4"
                    if [ "$buffer" = "$to_refresh" ]; then
                        line="$3"
                        enabled="$2"
                        if [ "$enabled" = y ]; then
                            flag="$kak_opt_gdb_breakpoint_active_symbol"
                        else
                            flag="$kak_opt_gdb_breakpoint_inactive_symbol"
                        fi
                        printf "set -add buffer gdb_breakpoints_flags '%s|%s'\n" "$line" "$flag"
                    fi
                    shift 4
                done
            }
        }
    }
}

def -hidden gdb-handle-print -params 1 %{
    try %{
        eval -buffer *gdb-print* %{
            reg '"' "%opt{gdb_expression_demanded} == %arg{1}"
            exec gep
            try %{ exec 'ggs\n<ret>d' }
        }
    }
    try %{ eval -client %opt{gdb_print_client} 'info "%opt{gdb_expression_demanded} == %arg{1}"' }
}

# clear all breakpoint information internal to kakoune
def -hidden gdb-clear-breakpoints %{
    eval -buffer * %{ unset buffer gdb_breakpoints_flags }
    set global gdb_breakpoints_info
}

def -hidden gdb-handle-perl-exited -params 1 %{
    try %{
        # only do this if the session that exited is the current one
        # this might not be the case if a session was started while another was active
        eval %sh{ [ "$kak_opt_gdb_dir" != "$1" ] && printf fail }

        # thoroughly clean all options
        set global gdb_started false
        set global gdb_program_running false
        set global gdb_program_stopped false
        set global gdb_indicator ""
        set global gdb_dir ""

        set global gdb_breakpoints_info
        set global gdb_location_info
        eval -buffer * %{
            unset buffer gdb_location_flag
            unset buffer gdb_breakpoint_flags
        }
        rmhl global/gdb-ref
        rmhooks global gdb-ref
    }
}
