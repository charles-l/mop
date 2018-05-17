struct SNDFILE;
struct ao_device;

// lifted from libao header

const enum AO_FMT_NATIVE = 4;
struct ao_sample_format {
	int  bits;
	int  rate;
	int  channels;
	int  byte_format;
        char *matrix;
};

// lifted from sndfile header

// we only every read, so this is the only enum value we need
const enum SFM_READ = 0x10;

struct SF_INFO {
    long frames;
    int samplerate;
    int channels;
    int format;
    int	sections;
    int	seekable;
}

enum {
    SF_FORMAT_PCM_S8 = 0x0001,
    SF_FORMAT_PCM_16 = 0x0002,
    SF_FORMAT_PCM_24 = 0x0003,
    SF_FORMAT_PCM_32 = 0x0004,
    SF_FORMAT_PCM_U8 = 0x0005,

    SF_FORMAT_SUBMASK = 0x0000FFFF,
};

enum {
    SF_STR_TITLE = 0x01,
    SF_STR_COPYRIGHT = 0x02,
    SF_STR_SOFTWARE = 0x03,
    SF_STR_ARTIST = 0x04,
    SF_STR_COMMENT = 0x05,
    SF_STR_DATE = 0x06,
    SF_STR_ALBUM = 0x07,
    SF_STR_LICENSE = 0x08,
    SF_STR_TRACKNUMBER = 0x09,
    SF_STR_GENRE = 0x10
};


const uint BUFFER_SIZE = 8192;

extern (C) void ao_initialize();
extern (C) SNDFILE *sf_open(const char *f, int, SF_INFO *sfinfo);
extern (C) immutable(char *) sf_get_string(SNDFILE *, int);
extern (C) int ao_driver_id(const char *);
extern (C) void ao_shutdown();
extern (C) int sf_read_short(SNDFILE *, short *buf, size_t);
extern (C) int ao_play(ao_device *, char *, uint);
extern (C) void ao_close(ao_device *);
extern (C) ao_device *ao_open_live(int, ao_sample_format *, void *);
extern (C) void sf_close(SNDFILE *);

import std.string;
import std.range;
import std.traits;
import std.path;
import std.parallelism;
import std.stdio;
import std.datetime.date;
import std.algorithm;
import std.file;
import std.exception;
import std.conv;
import std.typecons;
import core.thread;
import core.time;

ao_device *openDevice(SNDFILE *f, SF_INFO sfinfo, int driver) {
    ao_device *device;
    ao_sample_format format;

    printf("Samples: %d\n", sfinfo.frames);
    printf("Sample rate: %d\n", sfinfo.samplerate);
    printf("Channels: %d\n", sfinfo.channels);

    switch (sfinfo.format & SF_FORMAT_SUBMASK) {
        case SF_FORMAT_PCM_16:
            format.bits = 16;
            break;
        case SF_FORMAT_PCM_24:
            format.bits = 24;
            break;
        case SF_FORMAT_PCM_32:
            format.bits = 32;
            break;
        case SF_FORMAT_PCM_S8:
            format.bits = 8;
            break;
        case SF_FORMAT_PCM_U8:
            format.bits = 8;
            break;
        default:
            format.bits = 16;
            break;
    }


    format.channels = sfinfo.channels;
    format.rate = sfinfo.samplerate;
    format.byte_format = AO_FMT_NATIVE;
    format.matrix = null;

    device = ao_open_live(driver, &format, null);

    enforce(device != null, "error opening device");
    return device;
}

const enum State {PLAY, STOP, PAUSE};
const enum dump = 1; // dump attribute for dumpStruct

struct Status {
    Track *current;
    @dump {
        uint volume = 100;
        bool repeat = false;
        bool random = false;
        bool single = false;
        bool consume = false;
        uint playlist;
        uint playlistlength;
        State state = State.STOP;
        uint song;
        uint songid;
        uint nextsong;
        uint nextsongid;
        uint time;
        @property uint elapsed() {
            if(current)
                return current.time;
            else
                return 0;
        };
        uint duration;
        uint bitrate;
        uint xfade;
        float mixrampdb = 0.0;
        uint mixrampdelay;
    }
};

struct Stats {
    @dump {
        uint uptime;
        uint playtime;
        uint artists;
        uint albums;
        uint songs;
        uint db_playtime;
        uint db_update;
    }
};

struct Track {
    @dump {
        string file;
        DateTime last_modified;
        string artist;
        string album;
        string title;
        uint track;
        string genre;
        string date;
        string composer = "";
        uint disc = 0;
        string album_artist = "";
        uint time;
        float duration;
        uint id;
    }
};

template dumpStruct(T) {
    // dump instantiated struct
    void dumpStruct(T v) {
        static foreach (t; __traits(allMembers, T)) {
            static if ((cast(int[])[__traits(getAttributes, __traits(getMember, T, t))]).canFind(dump))
                writeln(t, ": ", __traits(getMember, v, t));
        }
    }
}

void sendError(string msg) {
    writeln("ACK [5@0] {} ", msg);
}

immutable string root = "/home/nc/mus/";

Track makeTrack(string path) {
    Track newTrack;

    SF_INFO i;
    SNDFILE *sfdata = sf_open(toStringz(path), SFM_READ, &i);
    scope (exit) sf_close(sfdata);

    enforce(sfdata != null, "failed to add file");

    newTrack.file = path;
    newTrack.last_modified = cast(DateTime) path.timeLastModified;
    newTrack.artist = fromStringz(sf_get_string(sfdata, SF_STR_ARTIST)).dup;
    newTrack.album = fromStringz(sf_get_string(sfdata, SF_STR_ALBUM)).dup;
    newTrack.title = fromStringz(sf_get_string(sfdata, SF_STR_TITLE)).dup;
    newTrack.track = to!uint(fromStringz(sf_get_string(sfdata, SF_STR_TRACKNUMBER)));
    newTrack.genre = fromStringz(sf_get_string(sfdata, SF_STR_GENRE)).dup;
    newTrack.date = fromStringz(sf_get_string(sfdata, SF_STR_DATE)).dup;

    return newTrack;
}

void addToPlaylist(ref Track[] playlist, Track t) {
    t.id = cast(uint) playlist.length + 1;
    playlist ~= t;
}

enum PlayerMessage {QUERY_TRACK, PLAY, PAUSE};

void main() {
    writeln("OK MPD 0.20.0");
    ao_initialize();
    int driver = ao_driver_id(toStringz("pulse"));
    assert(driver != -1);

    Status status;
    Stats stats;
    // TODO scan library and populate artists, albums and tracks

    Track[] playlist;

    // %%%
    SF_INFO i;
    SNDFILE *file;
    ao_device *device;

    short[BUFFER_SIZE * short.sizeof] buffer;

    void playTrack() {
        int pos = 0;

        while(true) {
            int read = sf_read_short(file, buffer.ptr, BUFFER_SIZE);
            if(!read) {
                return;
            }

            pos += read;

            status.current.time = pos / i.channels / i.samplerate;

            if(ao_play(device, cast(char *) buffer.ptr, cast(uint) (read * short.sizeof)) == 0) {
                throw new Exception("ao_play failed");
            }

            Fiber.yield();
        }
    }

    task({
            while(true) {
                stats.uptime++;
                if(status.state == State.PLAY) {
                    stats.playtime++;
                }

                Thread.sleep(1.seconds);
            }
    }).executeInNewThread();

    Fiber player;

    bool paused = false;

    void play(Track *t) {
        // cleanup previous track
        {
            if(file) {
                sf_close(file);
                file = null;
            }

            if(device) {
                ao_close(device);
                device = null;
            }
        }

        file = sf_open(toStringz(t.file), SFM_READ, &i);
        device = openDevice(file, i, driver);
        status.current = t;

        if(player) player.destroy();

        player = new Fiber(&playTrack);

        status.state = State.PLAY;
    }

    string[] reader() {
        return chomp(readln).split(" ");
    }

    auto getCommand = task(&reader);
    getCommand.executeInNewThread();
    while(true) {
        if(status.state == State.PLAY && !getCommand.done) {
            enforce(status.current);
            player.call();
        } else {
            try {
                string[] command = getCommand.yieldForce;

                switch(command[0]) {
                    // querying
                    case "status":
                        dumpStruct!Status(status);
                        break;
                    case "stats":
                        dumpStruct!Stats(stats);
                        break;
                    case "currentsong":
                        dumpStruct!Track(*status.current);
                        break;

                        // playback control
                    case "play":
                        uint pos = 0;
                        if(command[1])
                            pos = to!uint(command[1]);

                        play(&playlist[pos]);
                        break;
                    case "playid":
                        foreach(track; playlist) {
                            if(track.id == to!uint(command[1])) {
                                play(&track);
                                break;
                            }
                        }
                        break;
                    case "stop":
                        play(&playlist[0]);
                        status.state = State.STOP;
                        break;

                    case "next":
                        if(status.current + 1 < playlist.ptr + (playlist.length * Track.sizeof))
                            play(status.current + 1);
                        break;
                    case "previous":
                        if(status.current - 1 >= playlist.ptr)
                            play(status.current - 1);
                        break;

                    case "pause":
                        if(command.length > 1) {
                            if(to!uint(command[1]))
                                status.state = State.PAUSE;
                            else
                                status.state = State.PLAY;
                        } else {
                            if(status.state == State.PLAY)
                                status.state = State.PAUSE;
                            else if(status.state == State.PAUSE)
                                status.state = State.PLAY;
                        }
                        break;

                        // playlist
                    case "add":
                        string p = root ~ command.drop(1).join(" ");

                        char[256] msg;
                        enforce(p.exists, sformat(msg, "no such file or directory: %s", p));

                        if(p.isDir) {
                            foreach(t; p.dirEntries(SpanMode.depth)) {
                                writeln("adding", t);
                                try {
                                    playlist.addToPlaylist(makeTrack(t));
                                } catch(Exception e) {
                                    writeln("failed to add song");
                                }
                            }
                        } else {
                            playlist.addToPlaylist(makeTrack(p));
                        }

                        break;
                    case "playlistinfo":
                        playlist.each!(dumpStruct!Track);
                        break;
                    default:
                        throw new Exception("unknown command");
                }
            } catch(Exception e) {
                sendError(e.msg);
            } finally {
                getCommand = task(&reader);
                getCommand.executeInNewThread();
            }
        }
    }

    ao_shutdown();
}
