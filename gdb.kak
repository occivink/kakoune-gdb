# script summary:
# a long running shell process starts a gdb session (or connects to an existing one) and handles input/output
# kakoune -> gdb communication is done by writing the gdb commands to a fifo
# gdb -> kakoune communication is done by an awk process that translates gdb events into kakoune commands
# the gdb-handle-* commands act upon gdb notifications to update the kakoune state

declare-option str gdb_breakpoint_active_symbol "●"
declare-option str gdb_breakpoint_inactive_symbol "○"
declare-option str gdb_location_symbol "➡"

set-face global GdbBreakpoint red,default
set-face global GdbLocation blue,default

# a debugging session has been started
declare-option bool gdb_started false
# the debugged program is currently running (stopped or not)
declare-option bool gdb_program_running false
# the debugged program is currently running, but stopped
declare-option bool gdb_program_stopped false
# if not empty, contains the name of client in which the autojump is performed
declare-option str gdb_autojump_client
# if not empty, contains the name of client in which the value is printed
# set by default to the client which started the session
declare-option str gdb_print_client

# contains all known breakpoints in this format:
# id|enabled|line|file:id|enabled|line|file|:...
declare-option str-list gdb_breakpoints_info
# if execution is currently stopped, contains the location in this format:
# line|file
declare-option str gdb_location_info
# note that these variables may reference locations that are not in currently opened buffers

# list of pending commands that will be executed the next time the process is stopped
declare-option -hidden str gdb_pending_commands

# a visual indicator showing the current state of the script
declare-option str gdb_indicator

# the directory containing the input fifo, pty object and backtrace
declare-option -hidden str gdb_dir

# corresponding flags generated from the previous variables
# these are only set on buffer scope
declare-option -hidden line-specs gdb_breakpoints_flags
declare-option -hidden line-specs gdb_location_flag

addhl shared/gdb group -passes move
addhl shared/gdb/ flag-lines GdbLocation gdb_location_flag
addhl shared/gdb/ flag-lines GdbBreakpoint gdb_breakpoints_flags

define-command -params .. -file-completion gdb-session-new %{
    gdb-session-connect-internal
    nop %sh{
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
    nop %sh{
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
    eval %sh{
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
                    # QUOTE => \QUOTE
                    gsub("'\''", "\\'\''", print_value)
                    #gdb-handle-print QUOTE VALUE QUOTE
                    send("gdb-handle-print '\''" print_value "'\''")
                    printing = 0
                }
            }
            '
        } 2>/dev/null >/dev/null &
        printf "$!" > "${tmpdir}/pid"
        printf "set-option global gdb_dir %s\n" "$tmpdir"
        # put a dummy flag to prevent the columns from jiggling
        printf "set-option global gdb_location_flag 0 '0|%${#kak_opt_gdb_location_symbol}s'\n"
        printf "set-option global gdb_breakpoints_flags 0 '0|%${#kak_opt_gdb_breakpoint_active_symbol}s'\n"
    }
    set-option global gdb_started true
    set-option global gdb_print_client %val{client}
    gdb-set-indicator-from-current-state
    hook -group gdb global BufOpenFile .* %{
        gdb-refresh-location-flag %val{buffile}
        gdb-refresh-breakpoints-flags %val{buffile}
    }
    hook -group gdb global KakEnd .* %{
        gdb-session-stop
    }
    addhl global/gdb-ref ref -passes move gdb
}

define-command gdb-session-stop %{
    try %{
        eval %sh{ [ "$kak_opt_gdb_started" = false ] && printf fail }
        gdb-cmd quit
        nop %sh{
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
        set-option global gdb_print_client ""
        set-option global gdb_indicator ""
        set-option global gdb_dir ""

        set-option global gdb_breakpoints_info
        set-option global gdb_location_info ""
        eval -buffer * %{
            unset-option buffer gdb_location_flag
            unset-option buffer gdb_breakpoint_flags
        }
        rmhl global/gdb-ref
        remove-hooks global gdb-ref
    }
}

define-command gdb-jump-to-location %{
    eval %sh{
        [ "$kak_opt_gdb_stopped" = false ] && exit
        line="${kak_opt_gdb_location_info%%|*}"
        buffer="${kak_opt_gdb_location_info#*|}"
        printf "edit -existing \"%s\" %s\n" "$buffer" "$line"
    }
}

define-command -params 1.. gdb-cmd %{
    nop %sh{
        [ "$kak_opt_gdb_started" = false ] && exit
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
    try %{
        eval %sh{ [ -z "$1" ] && printf fail }
        gdb-cmd "print %arg{1}"
    } catch %{
        gdb-cmd "print %val{selection}"
    }
}

define-command gdb-enable-autojump %{
    try %{
        eval %sh{ [ "$kak_opt_gdb_started" = false ] && printf fail }
        set-option global gdb_autojump_client %val{client}
        gdb-set-indicator-from-current-state
    }
}
define-command gdb-disable-autojump %{
    set-option global gdb_autojump_client ""
    gdb-set-indicator-from-current-state
}
define-command gdb-toggle-autojump %{
    try %{
        eval %sh{ [ -z "$kak_opt_gdb_autojump_client" ] && printf fail }
        gdb-disable-autojump
    } catch %{
        gdb-enable-autojump
    }
}

declare-option -hidden int backtrace_current_line

define-command gdb-backtrace %{
    try %{
        eval %sh{
            [ "$kak_opt_gdb_stopped" = false ] && printf fail
            mkfifo "$kak_opt_gdb_dir"/backtrace
        }
        gdb-cmd -stack-list-frames
        eval -try-client %opt{toolsclient} %{
            edit! -fifo "%opt{gdb_dir}/backtrace" *gdb-backtrace*
            set buffer backtrace_current_line 0
            addhl buffer/ regex "^([^\n]*?):(\d+)" 1:cyan 2:green
            addhl buffer/ line '%opt{backtrace_current_line}' default+b
            map buffer normal <ret> ': gdb-backtrace-jump<ret>'
            hook -group fifo buffer BufCloseFifo .* %{
                nop %sh{ rm -f "$kak_opt_gdb_dir"/backtrace }
                #exec ged
                remove-hooks buffer fifo
            }
        }
    }
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
        buffer *gdb-backtrace*
        exec "%opt{backtrace_current_line}gk<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

define-command gdb-backtrace-down %{
    eval -try-client %opt{jumpclient} %{
        buffer *gdb-backtrace*
        exec "%opt{backtrace_current_line}gj<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

# implementation details

define-command -hidden gdb-set-indicator-from-current-state %{
    set-option global gdb_indicator %sh{
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
define-command gdb-breakpoint-impl -hidden -params 2 %{
    eval -draft %{
        # reduce to cursors so that we can just extract the line out of selections_desc without any hassle
        exec 'gh'
        eval %sh{
            if [ "$kak_opt_gdb_started" = false ]; then exit; fi
            delete="$1"
            create="$2"
            commands=$(
                # setting IFS is safe here because it's not arbitrary input
                eval set -- "$kak_opt_gdb_breakpoints_info"
                for selection in $kak_selections_desc; do
                    match=
                    cursor_line=${selection%%.*}
                    for current_bp in "$@"; do
                        buffer="${current_bp#*|*|*|}"
                        if [ "$buffer" = "$kak_buffile" ]; then
                            line_file="${current_bp#*|*|}"
                            line="${line_file%%|*}"
                            if [ "$line" = "$cursor_line" ]; then
                                match="$current_bp"
                                break
                            fi
                        fi
                    done
                    if [ -n "$match" ]; then
                        id="${match%%|*}"
                        [ "$delete" = false ] && continue
                        printf "delete %s\n" "$id"
                    else
                        [ "$create" = false ] && continue
                        printf "break %s:%s\n" "$kak_buffile" "$cursor_line"
                    fi
                done
            )
            if [ "$kak_opt_gdb_program_running" = false ] ||
                [ "$kak_opt_gdb_program_stopped" = true ]
            then
                printf "%s\n" "$commands" > "$kak_opt_gdb_dir"/input_pipe
            else
                printf "set-option global gdb_pending_commands '%s'" "$commands"
                # STOP!
                # breakpoint time
                echo "-exec-interrupt" > "$kak_opt_gdb_dir"/input_pipe
            fi
        }
    }
}


define-command -hidden -params 2 gdb-handle-stopped %{
    try %{
        gdb-process-pending-commands
        gdb-continue
    } catch %{
        set-option global gdb_program_stopped true
        gdb-set-indicator-from-current-state
        set-option global gdb_location_info "%arg{1}|%arg{2}"
        gdb-refresh-location-flag %arg{2}
        try %{ eval -client %opt{gdb_autojump_client} gdb-jump-to-location }
    }
}

define-command -hidden gdb-handle-stopped-unknown %{
    try %{
        gdb-process-pending-commands
        gdb-continue
    } catch %{
        set-option global gdb_program_stopped true
        gdb-set-indicator-from-current-state
    }
}

define-command -hidden gdb-handle-exited %{
    try %{ gdb-process-pending-commands }
    set-option global gdb_program_running false
    set-option global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

define-command -hidden gdb-process-pending-commands %{
    eval %sh{
        if [ ! -n "$kak_opt_gdb_pending_commands" ]; then
            printf fail
            exit
        fi
        printf "%s\n" "$kak_opt_gdb_pending_commands" > "$kak_opt_gdb_dir"/input_pipe
    }
    set-option global gdb_pending_commands ""
}

define-command -hidden gdb-handle-running %{
    set-option global gdb_program_running true
    set-option global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

define-command -hidden gdb-clear-location %{
    eval %sh{
        [ ! -n "$kak_opt_gdb_location_info" ] && exit
        buffer="${kak_opt_gdb_location_info#*|}"
        printf "unset-option \"buffer=%s\" gdb_location_flag\n" "$buffer"
    }
    set-option global gdb_location_info ""
}

# refresh the location flag of the buffer passed as argument
define-command -hidden -params 1 gdb-refresh-location-flag %{
    # buffer may not exist, only try
    try %{
        eval -buffer %arg{1} %{
            eval %sh{
                [ ! -n "$kak_opt_gdb_location_info" ] && exit
                buffer="${kak_opt_gdb_location_info#*|}"
                if [ "$1" = "$buffer" ]; then
                    line="${kak_opt_gdb_location_info%%|*}"
                    printf "set-option -add buffer gdb_location_flag \"%s|%s\"\n" "$line" "$kak_opt_gdb_location_symbol"
                fi
            }
        }
    }
}

define-command -hidden -params 4 gdb-handle-breakpoint-created %{
    set -add global gdb_breakpoints_info "%arg{1}|%arg{2}|%arg{3}|%arg{4}"
    gdb-refresh-breakpoints-flags %arg{4}
}

define-command -hidden -params 1 gdb-handle-breakpoint-deleted %{
    eval %sh{
        to_delete="$1"
        echo "set global gdb_breakpoints_info"
        eval set -- "$kak_opt_gdb_breakpoints_info"
        for current in "$@"; do
            id="${current%%|*}"
            if [ "$id" != "$to_delete" ]; then
                printf "set -add global gdb_breakpoints_info '%s'\n" "$current"
            else
                buffer="${current#*|*|*|}"
            fi
        done
        printf "gdb-refresh-breakpoints-flags '%s'\n" "$buffer"
    }
}

define-command -hidden -params 4 gdb-handle-breakpoint-modified %{
    eval %sh{
        id="$1"
        active="$2"
        line="$3"
        file="$4"
        echo "set global gdb_breakpoints_info"
        eval set -- "$kak_opt_gdb_breakpoints_info"
        for current in "$@"; do
            cur_id="${current%%|*}"
            if [ "$cur_id" != "$id" ]; then
                printf "set -add global gdb_breakpoints_info '%s'\n" "$current"
            else
                printf "set -add global gdb_breakpoints_info '%s|%s|%s|%s'\n" "$id" "$active" "$line" "$file"
            fi
        done
    }
    gdb-refresh-breakpoints-flags %arg{4}
}

# refresh the breakpoint flags of the file passed as argument
define-command -hidden -params 1 gdb-refresh-breakpoints-flags %{
    # buffer may not exist, so only try
    try %{
        eval -buffer %arg{1} %{
            unset-option buffer gdb_breakpoints_flags
            eval %sh{
                to_refresh="$1"
                eval set -- "$kak_opt_gdb_breakpoints_info"
                for current in "$@"; do
                    buffer="${current#*|*|*|}"
                    if [ "$buffer" = "$to_refresh" ]; then
                        current="${current#*|}"
                        enabled="${current%%|*}"
                        current="${current#*|}"
                        line="${current%%|*}"
                        if [ "$enabled" = y ]; then
                            flag="$kak_opt_gdb_breakpoint_active_symbol"
                        else
                            flag="$kak_opt_gdb_breakpoint_inactive_symbol"
                        fi
                        printf "set -add buffer gdb_breakpoints_flags '%s|%s'\n" "$line" "$flag"
                    fi
                done
            }
        }
    }
}

define-command -hidden gdb-handle-print -params 1 %{
    try %{
        eval -buffer *gdb-print* %{
            set-register '"' %arg{1}
            exec gep
            try %{ exec 'ggs\n<ret>d' }
        }
    }
    eval -client %opt{gdb_print_client} 'info %arg{1}'
}

# clear all breakpoint information internal to kakoune
define-command -hidden gdb-clear-breakpoints %{
    eval -buffer * %{ unset-option buffer gdb_breakpoints_flags }
    set-option global gdb_breakpoints_info
}
