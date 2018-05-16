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
import std.concurrency;
import std.stdio;
import std.datetime.date;
import std.algorithm;
import std.file;
import std.exception;
import std.conv;
import std.typecons;
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
        uint elapsed;
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

Stats stats;

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

void send_error(string msg) {
    writeln("ACK [5@0] {} ", msg);
}

const string root = "/home/nc/mus/";

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

enum PlayerMessage {QUERY_TRACK, PLAY, PAUSE};
void main() {
    writeln("OK MPD 0.20.0");
    ao_initialize();
    int driver = ao_driver_id(toStringz("pulse"));
    assert(driver != -1);

    Status status;

    Track[] playlist;

    auto playerF = (int driver) {
        short[BUFFER_SIZE * short.sizeof] buffer;

        bool playing = false;
        Track current;

        SNDFILE *file;
        SF_INFO i;
        ao_device *device;
        int pos = 0;
        bool complete = false;

        void init_from_current() {
            file = sf_open(toStringz(current.file), SFM_READ, &i);
            device = openDevice(file, i, driver);
            complete = false;
        }

        void cleanup() {
            if(file) {
                sf_close(file);
                file = null;
            }
            if(device) {
                ao_close(device);
                device = null;
            }
        }

        while(true) {
            receiveTimeout(dur!"nsecs"(-1),
                    (Track t) {
                        cleanup();
                        current = t;
                        init_from_current();
                    },
                    (PlayerMessage m) {
                        final switch(m) {
                        case PlayerMessage.PLAY:
                            playing = true;
                            break;
                        case PlayerMessage.PAUSE:
                            playing = false;
                            break;
                        case PlayerMessage.QUERY_TRACK:
                            ownerTid.send(Tuple!(Track, int)(current, complete ? pos : -1));
                            break;
                        }
                    });

            if(playing && file) {
                int read = sf_read_short(file, buffer.ptr, BUFFER_SIZE);
                if(!read) {
                    complete = true;
                    playing = false;
                    cleanup();
                }

                pos += read;

                current.time = pos / i.channels / i.samplerate;

                if(ao_play(device, cast(char *) buffer.ptr, cast(uint) (read * short.sizeof)) == 0) {
                    throw new Exception("ao_play failed");
                }
            }
        }
    };

    auto playerThread = spawn(playerF, driver);

    while(true) {
        stats.uptime++;

        string[] command = chomp(readln).split(" ");
        switch(command[0]) {
            // querying
            case "status":
                dumpStruct!Status(status);
                break;
            case "stats":
                dumpStruct!Stats(stats);
                break;
            case "currentsong":
                playerThread.send(PlayerMessage.QUERY_TRACK);
                auto x = receiveOnly!(Tuple!(Track, int));
                dumpStruct!Track(x[0]);
                break;

            // playback control
            case "play":
                uint pos = 0;
                if(command[1])
                    pos = to!uint(command[1]);
                playerThread.send(playlist[pos]);

                break;
            case "pause":
                if(to!uint(command[1]))
                    playerThread.send(PlayerMessage.PAUSE);
                else
                    playerThread.send(PlayerMessage.PLAY);
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
                            playlist ~= makeTrack(t);
                        } catch(Exception e) {
                            writeln("failed to add song");
                        }
                    }
                } else {
                    playlist ~= makeTrack(p);
                }

                break;
            case "playlistinfo":
                playlist.each!(dumpStruct!Track);
                break;
            default:
                throw new Exception("unknown command");
        }
    }
    ao_shutdown();
}
