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
# id enabled line file id enabled line file  ...
declare-option str-list gdb_breakpoints_info
# if execution is currently stopped, contains the location in this format:
# line file
declare-option str-list gdb_location_info
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
    info "Please instruct gdb to ""new-ui mi3 %opt{gdb_dir}/pty"""
}

define-command -hidden gdb-session-connect-internal %§
    gdb-session-stop
    eval %sh§§
        if ! command -v socat >/dev/null 2>&1 || ! command -v perl >/dev/null 2>&1; then
            printf "fail '''socat'' and ''perl'' must be installed to use this plugin'"
            exit
        fi
        export tmpdir=$(mktemp --tmpdir -d gdb_kak_XXX)
        mkfifo "${tmpdir}/input_pipe"
        {
            # too bad gdb only exposes its new-ui via a pty, instead of simply a socket
            tail -n +1 -f "${tmpdir}/input_pipe" | socat "pty,link=${tmpdir}/pty" STDIO,nonblock=1 | perl -e '
!!PLACEHOLDER!!'
        } 2>/dev/null >/dev/null &
        printf "$!" > "${tmpdir}/pid"
        printf "set-option global gdb_dir '%s'\n" "$tmpdir"
        # put an empty flag of the same width to prevent the columns from jiggling
        printf "set-option global gdb_location_flag 0 '0|%${#kak_opt_gdb_location_symbol}s'\n"
        printf "set-option global gdb_breakpoints_flags 0 '0|%${#kak_opt_gdb_breakpoint_active_symbol}s'\n"
    §§
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
§

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
        set-option global gdb_location_info
        eval -buffer * %{
            unset-option buffer gdb_location_flag
            unset-option buffer gdb_breakpoint_flags
        }
        rmhl global/gdb-ref
        remove-hooks global gdb-ref
    }
}

define-command gdb-jump-to-location %{
    try %{ eval %sh{
        eval set -- "$kak_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        line="$1"
        buffer="$2"
        printf "edit -existing '%s' %s; exec gi" "$buffer" "$line"
    }}
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

# gdb doesn't tell us in its output what was the expression we asked for, so keep it internally for printing later
declare-option -hidden str gdb_expression_demanded

define-command gdb-print -params ..1 %{
    try %{
        eval %sh{ [ -z "$1" ] && printf fail }
        set global gdb_expression_demanded %arg{1}
    } catch %{
        set global gdb_expression_demanded %val{selection}
    }
    gdb-cmd "-data-evaluate-expression ""%opt{gdb_expression_demanded}"""
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
            hook -always -once buffer BufCloseFifo .* %{
                nop %sh{ rm -f "$kak_opt_gdb_dir"/backtrace }
                exec ged
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
        set-option global gdb_location_info  %arg{1} %arg{2}
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
    try %{ eval %sh{
        eval set -- "$kak_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        buffer="$2"
        printf "unset 'buffer=%s' gdb_location_flag" "$buffer"
    }}
    set global gdb_location_info
}

# refresh the location flag of the buffer passed as argument
define-command -hidden -params 1 gdb-refresh-location-flag %{
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

define-command -hidden -params 4 gdb-handle-breakpoint-created %{
    set -add global gdb_breakpoints_info %arg{1} %arg{2} %arg{3} %arg{4}
    gdb-refresh-breakpoints-flags %arg{4}
}

define-command -hidden -params 1 gdb-handle-breakpoint-deleted %{
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

define-command -hidden -params 4 gdb-handle-breakpoint-modified %{
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
define-command -hidden -params 1 gdb-refresh-breakpoints-flags %{
    # buffer may not exist, so only try
    try %{
        eval -buffer %arg{1} %{
            unset-option buffer gdb_breakpoints_flags
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

define-command -hidden gdb-handle-print -params 1 %{
    try %{
        eval -buffer *gdb-print* %{
            set-register '"' "%opt{gdb_expression_demanded} == %arg{1}"
            exec gep
            try %{ exec 'ggs\n<ret>d' }
        }
    }
    try %{ eval -client %opt{gdb_print_client} 'info "%opt{gdb_expression_demanded} == %arg{1}"' }
}

# clear all breakpoint information internal to kakoune
define-command -hidden gdb-clear-breakpoints %{
    eval -buffer * %{ unset-option buffer gdb_breakpoints_flags }
    set-option global gdb_breakpoints_info
}
