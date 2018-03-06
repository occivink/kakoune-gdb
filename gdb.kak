# script summary:
# a long running shell process starts a gdb session (or connects to an existing one) and handles input/output
# kakoune -> gdb communication is done by writing the gdb commands to a fifo
# gdb -> kakoune communication is done by an awk process that translates gdb events into kakoune commands

declare-option str gdb_breakpoint_active_symbol "●"
declare-option str gdb_breakpoint_inactive_symbol "○"
declare-option str gdb_location_symbol "➡"

set-face GdbBreakpoint red,default
set-face GdbLocation blue,default

# a debugging session has been started
declare-option bool gdb_started false
# the debugged program is currently running (stopped or not)
declare-option bool gdb_program_running false
# the debugged program is currently running, but stopped
declare-option bool gdb_program_stopped false
# if not empty, contains the name of client in which the autojump is performed
declare-option str gdb_autojump_client

# contains all known breakpoints in this format:
# id|enabled|line|file:id|enabled|line|file|:...
declare-option str-list gdb_breakpoints_info
# if execution is currently stopped, contains the location in this format:
# line|file
declare-option str gdb_location_info
# note that these variables may reference locations that are not in currently opened buffers

# list of pending breakpoints, in this format:
# line|file:line|file:...
# "new" are the ones to be inserted, "old" are the ones to be deleted
declare-option -hidden str-list gdb_new_breakpoints_pending
declare-option -hidden str-list gdb_old_breakpoints_pending

# a visual indicator showing the current state of the script
declare-option str gdb_indicator

# the directory containing the input fifo, pty object and backtrace
declare-option -hidden str gdb_dir

# corresponding flags generated from the previous variables
# these are only set on buffer scope
declare-option -hidden line-specs gdb_breakpoints_flags
declare-option -hidden line-specs gdb_location_flag

add-highlighter shared/ group -passes move gdb
add-highlighter shared/gdb flag_lines GdbLocation gdb_location_flag
add-highlighter shared/gdb flag_lines GdbBreakpoint gdb_breakpoints_flags

define-command -params .. -file-completion gdb-session-new %{
    gdb-session-connect-internal
    %sh{
        # can't connect until socat has created the pty thing
        while [ ! -e "${kak_opt_gdb_dir}/pty" ]; do
            sleep 0.1
        done
        if [ -n "$TMUX" ]; then
            tmux split-window -h " \
                gdb $@ --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\""
        elif [ -n "$WINDOWID" ]; then
            setsid -w $kak_opt_termcmd " \
                gdb $@ --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\"" 2>/dev/null >/dev/null &
        fi
    }
}

define-command rr-session-new %{
    gdb-session-connect-internal
    %sh{
        # can't connect until socat has created the pty thing
        while [ ! -e "${kak_opt_gdb_dir}/pty" ]; do
            sleep 0.1
        done
        if [ -n "$TMUX" ]; then
            tmux split-window -h " \
                rr replay -o --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\""
        elif [ -n "$WINDOWID" ]; then
            setsid -w $kak_opt_termcmd " \
                rr replay -o --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\"" 2>/dev/null >/dev/null &
        fi
    }
}

define-command gdb-session-connect %{
    gdb-session-connect-internal
    info "Please instruct gdb to \"new-ui mi3 %opt{gdb_dir}/pty\""
}

define-command -hidden gdb-session-connect-internal %{
    gdb-session-stop
    %sh{
        tmpdir=$(mktemp --tmpdir -d gdb_kak_XXX)
        mkfifo "${tmpdir}/input_pipe"
        {
            tail -n +1 -f "${tmpdir}/input_pipe" | socat "pty,link=${tmpdir}/pty" STDIO,nonblock=1 | awk '
            function send(what) {
                cmd = "kak -p '"$kak_session"'"
                print(what) | cmd
                close(cmd)
            }
            function get(input, prefix, pattern, suffix) {
                s = match(input, prefix pattern suffix)
                return substr(input, s + length(prefix), RLENGTH - length(prefix) - length(suffix))
            }
            function breakpoint_info(breakpoint) {
                id = get(breakpoint, "number=\"", "[0-9]+", "\"")
                enabled = get(breakpoint, "enabled=\"", "[yn]", "\"")
                line = get(breakpoint, "line=\"", "[0-9]+", "\"")
                file = get(breakpoint, "fullname=\"", "[^\"]*", "\"")
                return id " " enabled " " line " \"" file "\""
            }
            function frame_info(frame) {
                file = get(frame, "fullname=\"", "[^\"]*", "\"")
                line = get(frame, "line=\"", "[0-9]+", "\"")
                if (line == "" || file == "")
                    return ""
                else
                    return line " \"" file "\""
            }
            BEGIN {
                connected = 0
                printing = 0
            }
            // {
                if (!connected) {
                    connected = 1
                    print("-gdb-set mi-async on") >> "'"$tmpdir/input_pipe"'"
                    print("-break-list") >> "'"$tmpdir/input_pipe"'"
                    print("-stack-info-frame") >> "'"$tmpdir/input_pipe"'"
                    close("'"$tmpdir/input_pipe"'")
                }
            }
            /^\*running/ {
                send("gdb-handle-running")
            }
            /^\*stopped/ {
                reason = get($0, "reason=\"", "[^\"]*", "\"")
                if (reason != "exited" && reason != "exited-normally" && reason != "exited-signalled") {
                    info = frame_info($0)
                    if (info == "")
                        send("gdb-handle-stopped-unknown")
                    else
                        send("gdb-handle-stopped " info)
                }
            }
            /^=thread-group-exited/ {
                send("gdb-handle-exited")
            }
            /\^done,frame=/ {
                send("gdb-clear-location; gdb-handle-stopped " frame_info($0))
            }
            /\^done,stack=/ {
                frames_number = split($0, frames, "frame=")
                for (i = 2; i <= frames_number; i++) {
                    frame = frames[i]
                    file = get(frame, "fullname=\"", "[^\"]*", "\"")
                    line = get(frame, "line=\"", "[0-9]+", "\"")
                    cmd = "awk \"NR==" line "\" \"" file "\""
                    cmd | getline call
                    close(cmd)
                    print(file ":" line ":" call) > "'"$tmpdir/backtrace"'"
                }
                close("'"$tmpdir/backtrace"'")
            }
            /^=breakpoint-created/ {
                send("gdb-handle-breakpoint-created " breakpoint_info($0))
            }
            /^=breakpoint-modified/ {
                send("gdb-handle-breakpoint-modified " breakpoint_info($0))
            }
            /^=breakpoint-deleted/ {
                id = get($0, "id=\"", "[0-9]+", "\"")
                send("gdb-handle-breakpoint-deleted " id)
            }
            /\^done,BreakpointTable=/ {
                command = "gdb-clear-breakpoints"
                breakpoints_number = split($0, breakpoints, "bkpt=")
                for (i = 2; i <= breakpoints_number; i++) {
                    command = command "; gdb-handle-breakpoint-created " breakpoint_info(breakpoints[i])
                }
                send(command)
            }
            /^\^error/ {
                msg = get($0, "msg=\"", ".*", "\"")
                gsub("'\''", "\\\\'\''", msg)
                send("echo -debug '\''" msg "'\''")
            }
            /^&"print/ {
                printing = 1
                var = get($0, "print ", ".*", "\"")
                gsub("\\\\n$", "", var)
                print_value = var " == "
            }
            /~".*"/ {
                if (printing == 1) {
                    append = get($0, "= ", ".*", "\"")
                    printing = 2
                } else if (printing) {
                    append = get($0, "\"", ".*","\"")
                }
                gsub("\\\\n$", "\n", append)
                print_value = print_value append
            }
            /\^done/ {
                if (printing) {
                    # QUOTE => \\QUOTE
                    gsub("'\''", "\\\\'\''", print_value)
                    # eval -client $client QUOTE info  -- \QUOTE $string \QUOTE QUOTE
                    send("eval -client '"$kak_client"' '\''info -- \\'\''" print_value "\\'\'\''")
                    printing = 0
                }
            }
            '
        } 2>/dev/null >/dev/null &
        printf "$!" > "${tmpdir}/pid"
        printf "set-option global gdb_dir %s\n" "$tmpdir"
        # put a dummy flag to prevent the columns from jiggling
        printf "set-option global gdb_location_flag '0:0|%${#kak_opt_gdb_location_symbol}s'\n"
        printf "set-option global gdb_breakpoints_flags '0:0|%${#kak_opt_gdb_breakpoint_active_symbol}s'\n"
    }
    set-option global gdb_started  true
    gdb-set-indicator-from-current-state
    hook -group gdb global BufOpenFile .* %{
        gdb-refresh-location-flag
        gdb-refresh-breakpoints-flags %val{buffile}
    }
    hook -group gdb global KakEnd .* %{
        gdb-session-stop
    }
    add-highlighter global ref -passes move gdb
}

define-command gdb-session-stop %{
    try %{
        %sh{
            if [ "$kak_opt_gdb_started" = false ]; then echo fail; fi
        }
        gdb-cmd quit
        %sh{
            #TODO: this might not be posix-compliant
            kill $(ps -o pid= --ppid $(cat "${kak_opt_gdb_dir}/pid"))
            rm -f "${kak_opt_gdb_dir}/pid" "${kak_opt_gdb_dir}/input_pipe"
            rmdir "$kak_opt_gdb_dir"
        }

        # thoroughly clean all options
        set-option global gdb_started false
        set-option global gdb_program_running false
        set-option global gdb_program_stopped false
        set-option global gdb_autojump_client ""
        set-option global gdb_indicator ""
        set-option global gdb_dir ""

        set-option global gdb_breakpoints_info ""
        set-option global gdb_location_info ""
        eval -buffer * %{
            unset-option buffer gdb_location_flag
            unset-option buffer gdb_breakpoint_flags
        }

        remove-highlighter global/gdb
        remove-hooks global gdb
    }
}

define-command gdb-jump-to-location %{
    %sh{
        if [ "$kak_opt_gdb_stopped" = false ]; then exit; fi
        line="${kak_opt_gdb_location_info%%|*}"
        buffer="${kak_opt_gdb_location_info#*|}"
        printf "edit -existing \"%s\" %s\n" "$buffer" "$line"
    }
}

define-command -params 1.. gdb-cmd %{
    %sh{
        if [ "$kak_opt_gdb_started" = false ]; then exit; fi
        IFS=' '
        printf %s\\n "$*"  > "$kak_opt_gdb_dir"/input_pipe
    }
}

define-command gdb-run -params ..    %{ gdb-cmd -exec-run %arg{@} }
define-command gdb-start -params ..  %{ gdb-cmd -exec-run --start %arg{@} }
define-command gdb-step              %{ gdb-cmd -exec-step }
define-command gdb-next              %{ gdb-cmd -exec-next }
define-command gdb-finish            %{ gdb-cmd -exec-finish }
define-command gdb-continue          %{ gdb-cmd -exec-continue }
define-command gdb-set-breakpoint    %{ gdb-breakpoint-impl false true }
define-command gdb-clear-breakpoint  %{ gdb-breakpoint-impl true false }
define-command gdb-toggle-breakpoint %{ gdb-breakpoint-impl true true }

define-command gdb-print -params ..1 %{
    %sh{
        if [ -n "$1" ]; then
            print="$1"
        else
            print="%val{selection}"
        fi
        printf "gdb-cmd \"print %s\"" "$print"
    }
}

define-command gdb-enable-autojump %{
    try %{
        %sh{
            if [ "$kak_opt_gdb_started" = false ]; then echo fail; fi
        }
        set-option global gdb_autojump_client %val{client}
        gdb-set-indicator-from-current-state
    }
}
define-command gdb-disable-autojump %{
    set-option global gdb_autojump_client ""
    gdb-set-indicator-from-current-state
}
define-command gdb-toggle-autojump %{
    %sh{
        if [ -n "$kak_opt_gdb_autojump_client" ]; then
            echo gdb-disable-autojump
        else
            echo gdb-enable-autojump
        fi
    }
}

declare-option -hidden int backtrace_current_line

define-command gdb-backtrace %{
    try %{
        %sh{
            if [ "$kak_opt_gdb_stopped" = false ]; then echo fail; fi
            mkfifo "$kak_opt_gdb_dir"/backtrace
        }
        gdb-cmd -stack-list-frames
        eval -try-client %opt{toolsclient} %{
            edit! -fifo "%opt{gdb_dir}/backtrace" *backtrace*
            set buffer filetype backtrace
            set buffer backtrace_current_line 0
            hook -group fifo buffer BufCloseFifo .* %{
                nop %sh{ rm -f "$kak_opt_gdb_dir"/backtrace }
                exec ged
                remove-hooks buffer fifo
            }
        }
    }
}

hook -group backtrace-highlight global BufSetOption filetype=backtrace %{
    add-highlighter buffer group backtrace
    add-highlighter buffer/backtrace regex "^([^\n]*?):(\d+)" 1:cyan 2:green
    add-highlighter buffer/backtrace line '%opt{backtrace_current_line}' default+b
    map buffer normal <ret> :gdb-backtrace-jump<ret>
}

hook global BufSetOption filetype=(?!backtrace).* %{
    remove-highlighter buffer/backtrace
    unmap buffer normal <ret> :gdb-backtrace-jump<ret>
}

define-command -hidden gdb-backtrace-jump %{
    eval %{
        try %{
            exec -save-regs '' 'xs^([^:]+):(\d+)<ret>'
            set buffer backtrace_current_line %val{cursor_line}
            eval -try-client %opt{jumpclient} "edit -existing %reg{1} %reg{2}"
            try %{ focus %opt{jumpclient} }
        }
    }
}

define-command gdb-backtrace-up %{
    eval -try-client %opt{jumpclient} %{
        buffer *backtrace*
        exec "%opt{backtrace_current_line}gk<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

define-command gdb-backtrace-down %{
    eval -try-client %opt{jumpclient} %{
        buffer *backtrace*
        exec "%opt{backtrace_current_line}gj<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

# implementation details

define-command -hidden gdb-set-indicator-from-current-state %{
    set-option global gdb_indicator "%sh{
        if [ \"$kak_opt_gdb_started\" = false ]; then exit; fi
        printf 'gdb '
        a=$(
            [ \"$kak_opt_gdb_program_running\" = true ] && printf '[running]'
            [ \"$kak_opt_gdb_program_stopped\" = true ] && printf '[stopped]'
            [ -n \"$kak_opt_gdb_autojump_client\" ] && printf '[autojump]'
        )
        [ -n \"$a\" ] && printf \"$a \"
    }"
}

# the two params are bool that indicate the following
# if %arg{1} == true, existing breakpoints where there is a cursor are cleared (untouched otherwise)
# if %arg{2} == true, new breakpoints are set where there is a cursor and no breakpoint (not created otherwise)
define-command gdb-breakpoint-impl -hidden -params 2 %{
    try %{
        eval -draft %{
            # reduce to cursors so that we can just extract the line out of selections_desc without any hassle
            exec '<a-x>gh'
            %sh{
                if [ "$kak_opt_gdb_started" = false ]; then exit; fi
                # setting IFS is safe here because it's not arbitrary input
                IFS=:
                lines_with_breakpoints=$(
                    for current in $kak_opt_gdb_breakpoints_info; do
                        buffer="${current#*|*|*|}"
                        if [ "$buffer" = "$kak_buffile" ]; then
                            line_file="${current#*|*|}"
                            line="${line_file%%|*}"
                            printf "%s:" "$line"
                        fi
                    done
                )
                line_has_breakpoint() {
                    for tmp in $lines_with_breakpoints; do
                        if [ "$1" = "$tmp" ]; then
                            return 0
                        fi
                    done
                    return 1
                }
                if [ "$kak_opt_gdb_program_running" = false ] ||
                    [ "$kak_opt_gdb_program_stopped" = true ]
                then
                    # not started or stopped, we can safely manipulate the breakpoints directly
                    for i in $kak_selections_desc; do
                        line=${i%%.*}
                        if line_has_breakpoint $line; then
                            [ "$1" = false ] && continue
                            op="clear"
                        else
                            [ "$2" = false ] && continue
                            op="break"
                        fi
                        printf "%s %s:%s\n" "$op" "$kak_buffile" "$line"
                    done > "$kak_opt_gdb_dir"/input_pipe
                else
                    if [ -n "$kak_opt_gdb_old_breakpoints_pending" ] ||
                        [ -n "$kak_opt_gdb_new_breakpoints_pending" ]
                    then
                        echo fail
                        exit
                    fi
                    # running, we first have to stop the program
                    for i in $kak_selections_desc; do
                        line=${i%%.*}
                        if line_has_breakpoint $line; then
                            [ "$1" = false ] && continue
                            state="old"
                        else
                            [ "$2" = false ] && continue
                            state="new"
                        fi
                        printf "set-option -add global gdb_%s_breakpoints_pending \"%s|%s\"\n" "$state" "$line" "$kak_buffile"
                    done
                    # STOP!
                    # breakpoint time
                    echo "-exec-interrupt" > "$kak_opt_gdb_dir"/input_pipe
                fi
            }
        }
    } catch %{
        echo -markup "{black,red}Pending operations in progress"
    }
}


define-command -hidden -params 2 gdb-handle-stopped %{
    try %{
        gdb-handle-pending-breakpoints
        gdb-continue
    } catch %{
        set-option global gdb_program_stopped true
        gdb-set-indicator-from-current-state
        set-option global gdb_location_info "%arg{1}|%arg{2}"
        gdb-refresh-location-flag
        try %{ eval -client %opt{gdb_autojump_client} gdb-jump-to-location }
    }
}

define-command -hidden gdb-handle-stopped-unknown %{
    try %{
        gdb-handle-pending-breakpoints
        gdb-continue
    } catch %{
        set-option global gdb_program_stopped true
        gdb-set-indicator-from-current-state
    }
}

define-command -hidden gdb-handle-exited %{
    try %{ gdb-handle-pending-breakpoints }
    set-option global gdb_program_running false
    set-option global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

define-command -hidden gdb-handle-pending-breakpoints %{
    %sh{
        if [ ! -n "$kak_opt_gdb_old_breakpoints_pending" ] && [ ! -n "$kak_opt_gdb_new_breakpoints_pending" ]; then
            echo fail
            exit
        fi
        {
            IFS=:
            for i in $kak_opt_gdb_old_breakpoints_pending; do
                line=${i%%|*}
                file=${i#*|}
                printf "clear %s:%s\n" "$file" "$line"
            done
            for i in $kak_opt_gdb_new_breakpoints_pending; do
                line=${i%%|*}
                file=${i#*|}
                printf "break %s:%s\n" "$file" "$line"
            done
        } > "$kak_opt_gdb_dir"/input_pipe
    }
    set-option global gdb_old_breakpoints_pending ""
    set-option global gdb_new_breakpoints_pending ""
}

define-command -hidden gdb-handle-running %{
    set-option global gdb_program_running true
    set-option global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

define-command -hidden gdb-clear-location %{
    %sh{
        if [ ! -n "$kak_opt_gdb_location_info" ]; then exit; fi
        buffer="${kak_opt_gdb_location_info#*|}"
        printf "unset-option \"buffer=%s\" gdb_location_flag\n" "$buffer"
    }
    set-option global gdb_location_info ""
}

define-command -hidden gdb-refresh-location-flag %{
    %sh{
        if [ ! -n "$kak_opt_gdb_location_info" ]; then exit; fi
        line="${kak_opt_gdb_location_info%%|*}"
        buffer="${kak_opt_gdb_location_info#*|}"
        printf "try %%{ set-option -add \"buffer=%s\" gdb_location_flag \"%s|%s\" }\n" "$buffer" "$line" "$kak_opt_gdb_location_symbol"
    }
}

define-command -hidden -params 4 gdb-handle-breakpoint-created %{
    set-option -add global gdb_breakpoints_info "%arg{1}|%arg{2}|%arg{3}|%arg{4}"
    gdb-refresh-breakpoints-flags %arg{4}
}

define-command -hidden -params 1 gdb-handle-breakpoint-deleted %{
    %sh{
        echo "set-option global gdb_breakpoints_info ''"
        IFS=:
        for current in $kak_opt_gdb_breakpoints_info; do
            id="${current%%|*}"
            if [ "$id" != "$1" ]; then
                printf "set-option -add global gdb_breakpoints_info \"%s\"\n" "$current"
            else
                buffer="${current#*|*|*|}"
            fi
        done
        printf "gdb-refresh-breakpoints-flags \"%s\"\n" "$buffer"
    }
}

define-command -hidden -params 4 gdb-handle-breakpoint-modified %{
    %sh{
        echo "set-option global gdb_breakpoints_info ''"
        IFS=:
        for current in $kak_opt_gdb_breakpoints_info; do
            id="${current%%|*}"
            if [ "$id" != "$1" ]; then
                printf "set-option -add global gdb_breakpoints_info \"%s\"\n" "$current"
            else
                printf "set-option -add global gdb_breakpoints_info \"%s|%s|%s|%s\"\n" "$1" "$2" "$3" "$4"
            fi
        done
    }
    gdb-refresh-breakpoints-flags %arg{4}
}

# refresh the breakpoint indicators of the file passed as parameter
define-command -hidden -params 1 gdb-refresh-breakpoints-flags %{
    # buffer may not exist, so only try
    try %{
        unset-option "buffer=%arg{1}" gdb_breakpoints_flags
        %sh{
            IFS=:
            for current in $kak_opt_gdb_breakpoints_info; do
                buffer="${current#*|*|*|}"
                if [ "$buffer" = "$1" ]; then
                    current="${current#*|}"
                    enabled="${current%%|*}"
                    current="${current#*|}"
                    line="${current%%|*}"
                    if [ "$enabled" = y ]; then
                        flag="$kak_opt_gdb_breakpoint_active_symbol"
                    else
                        flag="$kak_opt_gdb_breakpoint_inactive_symbol"
                    fi
                    printf "set-option -add \"buffer=%s\" gdb_breakpoints_flags %s|%s\n" "$buffer" "$line" "$flag"
                fi
            done
        }
    }
}

# clear all breakpoint information internal to kakoune
define-command -hidden gdb-clear-breakpoints %{
    eval -buffer * %{ unset-option buffer gdb_breakpoints_flags }
    set-option global gdb_breakpoints_info ""
}

