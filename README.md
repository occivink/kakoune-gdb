# kakoune-gdb

[kakoune](http://kakoune.org) plugin to provide integration with gdb.

## Setup

Add `gdb.kak` to your autoload dir: `~/.config/kak/autoload/`, or source it manually. Optionally, add `gdb-helper.kak` to get higher-level commands meant to simplify the workflow.

This script has hard dependencies on `gdb` (duh) and `socat`, as well as the usual POSIX environment. There is also on optional dependency on `rr`. 

## Usage

### Interfacing with gdb

The first step in using the script is to connect kakoune and gdb together.
There are multiple ways to do this, detailed below:

#### Starting a gdb session

If you wish to start a new debugging session, you should call `gdb-session-new`. A new gdb instance will be started, already connected to kakoune.
Any additional command parameters will be passed to gdb (in particular, the executable you wish to debug).

#### Using rr

If you use [rr](http://rr-project.org/), you can call `rr-session-new`. A new gdb instance will be started with the latest rr recording.

#### Connecting to an existing session

If you already have a running session of gdb but want to make kakoune aware of it, call `gdb-session-connect`. The infobox will show you a command that you should call in gdb directly. Once that is done, kakoune will be connected to gdb and all pre-existing gdb state will be shown.

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
| `gdb-advance` | `advance` | continue execution until it reaches the cursor location or exits the current function |
| `gdb-jump-to-location` | - | if execution is stopped, jump to the location |
| `gdb-set-breakpoint` | `break` | set a breakpoint at the cursor location |
| `gdb-clear-breakpoint` | `clear` | remove any breakpoints at the cursor location |
| `gdb-toggle-breakpoint` | - | remove or set a breakpoint at the cursor location|
| `gdb-print` | `print` | print the value of the currently selected expression in an infobox |
| `gdb-backtrace` | `backtrace` | show the callstack in a scratch buffer |

The backtrace view can be navigated using `<ret>` to jump to the selected function.

The `gdb-{enable,disable,toggle}-autojump` commands let you control if the current client should jump to the current location when execution is stopped.

The `gdb-helper.kak` script wraps these commands in shortcuts and shows an infobox detailing them. The `gdb-helper` command provides one-off shortcuts, and `gdb-helper-repeat` leaves the shortcuts on until `<esc>` is pressed.

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

It is possible to show in the modeline the status of the plugin, using the options `gdb_indicator` and `gdb_autojump_indicator`. In the demo, I use:
```
set global modelinefmt '%val{bufname} %val{cursor_line}:%val{cursor_char_column} {{context_info}} {{mode_info}} {red,default}%opt{gdb_indicator}%opt{gdb_autojump_indicator}{default,default}- %val{client}@[%val{session}]'
```

## License

Unlicense
