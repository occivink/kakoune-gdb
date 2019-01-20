# kakoune-gdb

[kakoune](http://kakoune.org) plugin for gdb integration.

[![demo](https://asciinema.org/a/164340.png)](https://asciinema.org/a/164340)

## Setup

Add `gdb.kak` to your autoload dir: `~/.config/kak/autoload/`, or source it manually.

You need at least Kakoune v2019.01.20. In addition, this script has hard dependencies on `gdb` (>= 7.12), `socat`, `perl` as well as the usual POSIX environment. There is also on optional dependency on `rr`.

## Usage

### Interfacing with gdb

The first step in using the script is to connect kakoune and gdb together.
There are multiple ways to do this, detailed below:

#### Starting a gdb session

If you wish to start a new debugging session, you should call `gdb-session-new`. A new gdb instance will be started, already connected to kakoune.
Any additional command parameters will be passed to gdb (in particular, the executable you wish to debug).

If you wish to use a different program than `gdb` (for example a wrapper script like `rust-gdb`), you can set the `gdb_program` option.

#### Using rr

If you use [rr](http://rr-project.org/), you can call `rr-session-new`. A new gdb instance will be started with the latest rr recording.

#### Connecting to an existing session

If you already have a running session of gdb but want to make kakoune aware of it, call `gdb-session-connect`. The infobox will show you a command that you should call in gdb directly. Once that is done, kakoune will be connected to gdb and all pre-existing gdb state will be shown.  
**Warning**: for this to work properly, the `mi-async` gdb variable must be set to `on` BEFORE the debugged program has been started.

### Controlling gdb

Once kakoune is connected to gdb, gdb can be controlled normally from its REPL or by issuing commands from kakoune's side.  
Kakoune will then be updated in real-time to show the current state of gdb (current line, breakpoints and whether they are enabled).  
The script provides commands for the most common operations; complex ones should be done in the gdb REPL directly.

| kakoune command | gdb equivalent | Description |
| --- | --- | --- |
| `gdb-run` | `run` | start the program |
| `gdb-start` | `start` | start the program and pause right away |
| `gdb-step` | `step` | execute the next line, entering the function if applicable (step in) |
| `gdb-next` | `next` | execute the next line of the current function (step over)|
| `gdb-finish` | `finish` | continue execution until the end of the current function (step out)|
| `gdb-continue` | `continue` | continue execution until the next breakpoint |
| `gdb-jump-to-location` | - | if execution is stopped, jump to the location |
| `gdb-set-breakpoint` | `break` | set a breakpoint at the cursor location |
| `gdb-clear-breakpoint` | `clear` | remove any breakpoints at the cursor location |
| `gdb-toggle-breakpoint` | - | remove or set a breakpoint at the cursor location|
| `gdb-print` | `print` | print the value of the currently selected expression in an infobox (and in the buffer `*gdb-print*` if it exists) |
| `gdb-backtrace` | `backtrace` | show the callstack in a scratch buffer |

The backtrace view can be navigated using `<ret>` to jump to the selected function.

The `gdb-{enable,disable,toggle}-autojump` commands let you control if the current client should jump to the current location when execution is stopped.

### Extending the script

This script can be extended by defining your own commands. `gdb-cmd` is provided for that purpose: it simply forwards its arguments to the gdb process. Some of the predefined commands are defined like that:
```
define-command gdb-run -params ..    %{ gdb-cmd -exec-run %arg{@} }
define-command gdb-start -params ..  %{ gdb-cmd -exec-run --start %arg{@} }
define-command gdb-step              %{ gdb-cmd -exec-step }
define-command gdb-next              %{ gdb-cmd -exec-next }
define-command gdb-finish            %{ gdb-cmd -exec-finish }
define-command gdb-continue          %{ gdb-cmd -exec-continue }
```

You can also use the existing options to further refine your commands. Some of these are read-only (`[R]`), some can also be written to (`[RW]`).
* `gdb_started`[bool][R]        : true if a debugging session has been started
* `gdb_program_running`[bool][R]: true if the debugged program is currently running (stopped or not)
* `gdb_program_stopped`[bool][R]: true if the debugged program is currently running, and stopped
* `gdb_autojump_client`[str][RW]: if autojump is enabled, the name of the client in which the jump is performed
* `gdb_print_client`[str][RW]   : the name of the client in which the value is printed
* `gdb_location_info`[str][R]   : if running and stopped, contains the location in the format `line` `file`
* `gdb_breakpoints_info`[str][R]: contains all known breakpoints in the format `id1` `enabled1` `line1` `file1` `id2` `enabled2` `line2` `file2` ...

### Customization

The gutter symbols can be modified by changing the values of these options: 
```
gdb_breakpoint_active_symbol
gdb_breakpoint_inactive_symbol
gdb_location_symbol
```
as well as their associated faces:
```
GdbBreakpoint
GdbLocation
```

It is possible to show in the modeline the status of the plugin using the option `gdb_indicator`. In the demo, I use:
```
set global modelinefmt '%val{bufname} %val{cursor_line}:%val{cursor_char_column} {{context_info}} {{mode_info}} {red,default}%opt{gdb_indicator}{default,default}- %val{client}@[%val{session}]'
```

To setup "standard" debugger shortcuts, you can use the following snippet:
```
hook global GlobalSetOption gdb_started=true %{
    map global normal <f10>   ': gdb-next<ret>'
    map global normal <f11>   ': gdb-step<ret>'
    map global normal <s-f11> ': gdb-finish<ret>'
    map global normal <f9>    ': gdb-toggle-breakpoint<ret>'
    map global normal <f5>    ': gdb-continue<ret>'
}
hook global GlobalSetOption gdb_started=false %{
    unmap global normal <f10>   ': gdb-next<ret>'
    unmap global normal <f11>   ': gdb-step<ret>'
    unmap global normal <s-f11> ': gdb-finish<ret>'
    unmap global normal <f9>    ': gdb-toggle-breakpoint<ret>'
    unmap global normal <f5>    ': gdb-continue<ret>'
}
```

## TODO

* set temporary/conditional breakpoints
* handle up/down, and moving the current frame from the backtrace buffer

## License

Unlicense
