# override to allow starting wrapper scripts
# they must be compatible with gdb arguments
decl str gdb_program "gdb"

decl -hidden str gdb_output_handler %sh{ printf "%s/%s" "${kak_source%/*}" "gdb-output-handler.perl" }

decl bool gdb_debug false

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
# if not empty, contains the name of the client in which the autojump is performed
decl str gdb_autojump_client
# if not empty, contains the name of the client in which the value is printed
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

eval %{
    try %{
        %sh{ [ gdb_debug = "false" ] && printf 'fail' }
        def gdb-debug -hidden -params .. ''
    } catch %{
        def gdb-debug -hidden -params .. %{ echo -debug '[gdb][kak]' %arg{@} }
    }
}

def -params .. -file-completion gdb-session-new %{
    gdb-session-connect-internal
    nop %sh{
        # can't connect until socat has created the pty thing
        while [ ! -e "${kak_opt_gdb_dir}/pty" ]; do
            sleep 0.1
        done
    }
    terminal %opt{gdb_program} --init-eval-command "set mi-async on" --init-eval-command "new-ui mi3 %opt{gdb_dir}/pty" %arg{@}
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
        export tmpdir=$(mktemp -t -d gdb_kak_XXX)
        mkfifo "${tmpdir}/input_pipe"
        {
            # too bad gdb only exposes its new-ui via a pty, instead of simply a socket
            # the 'wait-slave' argument makes socat exit when the other end of the pty (gdb) exits, which is exactly what we want
            # 'setsid socat' allows us to ignore any ctrl+c sent from kakoune
            tail -n +1 -f "${tmpdir}/input_pipe" | setsid socat "pty,wait-slave,link=${tmpdir}/pty" STDIO,nonblock=1 | perl "$kak_opt_gdb_output_handler"
            # when the perl program finishes (crashed or gdb closed the pty), cleanup and tell kakoune to stop the session
            rm -f "${tmpdir}/input_pipe"
            rmdir "$tmpdir"
            printf "gdb-handle-perl-exited '%s'" "${tmpdir}" | kak -p $kak_session
        } > /dev/null 2>&1 < /dev/null &
        printf "set global gdb_dir '%s'\n" "$tmpdir"
        # put an empty flag of the same width to prevent the columns from jiggling
        # TODO: support double-width characters (?)
        printf "set global gdb_location_flag 0 '0|%s'\n" "$kak_opt_gdb_location_symbol"
        printf "set global gdb_breakpoints_flags 0 '0|%s'\n" "$kak_opt_gdb_breakpoint_active_symbol"
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
        eval set -- "$kak_quoted_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        line="$1"
        buffer="$2"
        printf "edit -existing '%s' %s; exec gi" "$buffer" "$line"
    }}
}

def gdb-cmd -params 1.. %{
    gdb-debug gdb-cmd %arg{@}
    eval %sh{
        if [ "$kak_opt_gdb_started" = false ] || [ ! -p "$kak_opt_gdb_dir"/input_pipe ]; then
            printf "fail 'This command must be executed in a gdb session'"
            exit
        fi
        {
            cat <<'EOF' | perl - "$@"
use strict;
use warnings;
foreach my $arg (@ARGV) {
    if ($arg =~ /^[A-Za-z0-9-_]+$/) {
        # print as-is
        print($arg . " ");
    } elsif ($arg eq "\n") {
        print("\n");
    } elsif ($arg eq "") {
        print("''");
    } else {
        # escape \ and " with a \
        $arg =~ s/([\\"])/\\$1/g;
        print('"' . $arg . '" ');
    }
}
print("\n");
EOF
        } > "$kak_opt_gdb_dir"/input_pipe
    }
}

def gdb-session-stop      %{ gdb-cmd "-gdb-exit" }
def gdb-run -params ..    %{ gdb-cmd '-exec-arguments' %arg{@} '
' '-exec-run' }
def gdb-start -params ..  %{ gdb-cmd '-exec-arguments' %arg{@} '
' '-exec-run' '--start' }
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
    gdb-cmd -data-evaluate-expression "%opt{gdb_expression_demanded}"
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
            # if autojump is enabled, this should trigger a jump
            # neat
            gdb-cmd 'frame' %sh{ printf '%s' $(( kak_cursor_line - 1 )) }
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
                    eval set -- "$kak_quoted_opt_gdb_breakpoints_info"
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
    gdb-debug gdb-handle-stopped %arg{@}
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
    gdb-debug gdb-handle-stopped-unknown
    try %{
        gdb-process-pending-commands
        gdb-continue
    } catch %{
        set global gdb_program_stopped true
        gdb-set-indicator-from-current-state
    }
}

def -hidden gdb-handle-exited %{
    gdb-debug gdb-handle-exited
    try %{ gdb-process-pending-commands }
    set global gdb_program_running false
    set global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

def -hidden gdb-process-pending-commands %{
    gdb-debug gdb-process-pending-commands
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
    gdb-debug gdb-handle-running
    set global gdb_program_running true
    set global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

def -hidden gdb-clear-location %{
    gdb-debug gdb-clear-location
    try %{ eval %sh{
        eval set -- "$kak_quoted_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        buffer="$2"
        printf "unset 'buffer=%s' gdb_location_flag" "$buffer"
    }}
    set global gdb_location_info
}

# refresh the location flag of the buffer passed as argument
def -hidden -params 1 gdb-refresh-location-flag %{
    gdb-debug gdb-refresh-location-flag %arg{@}
    # buffer may not exist, only try
    try %{
        eval -buffer %arg{1} %{
            set buffer gdb_location_flag %val{timestamp} "0|%opt{gdb_location_symbol}"
            eval %sh{
                buffer_to_refresh="$1"
                eval set -- "$kak_quoted_opt_gdb_location_info"
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
    gdb-debug gdb-handle-breakpoint-created %arg{@}
    set -add global gdb_breakpoints_info %arg{1} %arg{2} %arg{3} %arg{4}
    gdb-refresh-breakpoints-flags %arg{4}
}

def -hidden -params 1 gdb-handle-breakpoint-deleted %{
    gdb-debug gdb-handle-breakpoint-deleted %arg{@}
    eval %sh{
        id_to_delete="$1"
        printf "set global gdb_breakpoints_info\n"
        eval set -- "$kak_quoted_opt_gdb_breakpoints_info"
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
    gdb-debug gdb-handle-breakpoint-modified %arg{@}
    eval %sh{
        id_modified="$1"
        active="$2"
        line="$3"
        file="$4"
        printf "set global gdb_breakpoints_info\n"
        eval set -- "$kak_quoted_opt_gdb_breakpoints_info"
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
    gdb-debug gdb-refresh-breakpoints-flags %arg{@}
    # buffer may not exist, so only try
    try %{
        eval -buffer %arg{1} %{
            set buffer gdb_breakpoints_flags %val{timestamp} "0|%opt{gdb_breakpoint_active_symbol}"
            eval %sh{
                to_refresh="$1"
                eval set -- "$kak_quoted_opt_gdb_breakpoints_info"
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
    gdb-debug gdb-handle-print %arg{@}
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
    gdb-debug gdb-clear-breakpoints
    eval -buffer * %{ unset buffer gdb_breakpoints_flags }
    set global gdb_breakpoints_info
}

def -hidden gdb-handle-perl-exited -params 1 %{
    gdb-debug gdb-handle-perl-exited %arg{@}
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
