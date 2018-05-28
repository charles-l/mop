# mop
### an mpd reimplementation in D

Still very alpha - but I've started dogfooding it, so it should improve soon.

# what's implemented
* ogg, flac and mp3 support playback support
* adding stuff from your library
* shuffling (that's slightly borked)
* works with `mpc` somewhat (but not `ncmpcpp` yet)

# what needs to be added
* configuration
* serializing library
* performance tuning
* integration with other clients

# usage
* clone repo
* update `mop.d`:
    * set `root` variable to music root directory
    * set `port` variable (6600 for regular use)
* build it with `make`
