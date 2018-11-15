#!/bin/sh
cd $(dirname $(readlink -f "$0"))
# embed the perl prog into the kak script
kak -n -ui dummy -e '
try %{
   edit gdb_output_handler.perl
   # replace single-quote with single-quote-backslash-single-quote-single-quote
   # which is the posix shell way of having singe-quotes inside single-quote-strings
   try %{
       exec %{ %s'\''<ret>yPpi\<esc> }
   }
   # double up § characters, not that there is much chance to find any
   try %{
       exec %{ %s§<ret>yP }
   }
   exec -save-regs "" %{ %y }
   edit gdb.kak
   exec %{ %s!!PLACEHOLDER!!<ret>R }
   write -sync ../gdb.kak
   quit! 0
} catch %{
   quit! 1
}'
