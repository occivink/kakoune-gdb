The files in this directory only serve to generate to top-level `gdb.kak` and you can safely ignore them if you don't plan on working on this plugin.

The `build.sh` script merges `gdb.kak.tmp` and `gdb_output_handler.perl` to generate `../gdb.kak`. 
The advantage is in simplifying development: the two sides (input/output) of the plugin can be developed separately, quoting is taken care of by the build script when embedding, and the perl script can be tested "offline" on sample output.
