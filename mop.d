import core.stdc.stdint;
import std.string;
import std.range;
import std.traits;
import std.path;
import std.parallelism;
import std.concurrency;
import std.stdio;
import std.datetime.date;
import std.algorithm;
import std.file;
import std.exception;
import std.conv;
import std.typecons;
import std.socket;
import core.thread;
import core.time;

//// FFI ////

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
    int64_t frames;
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

// lifted from mpd header

enum Ack {
	ERROR_NOT_LIST = 1,
	ERROR_ARG = 2,
	ERROR_PASSWORD = 3,
	ERROR_PERMISSION = 4,
	ERROR_UNKNOWN = 5,

	ERROR_NO_EXIST = 50,
	ERROR_PLAYLIST_MAX = 51,
	ERROR_SYSTEM = 52,
	ERROR_PLAYLIST_LOAD = 53,
	ERROR_UPDATE_ALREADY = 54,
	ERROR_PLAYER_SYNC = 55,
	ERROR_EXIST = 56,
};

const uint BUFFER_SIZE = 8192;

extern (C) void ao_initialize();
extern (C) SNDFILE *sf_open(const char *, int, SF_INFO *);
extern (C) int64_t sf_seek(SNDFILE *, int64_t, int);
extern (C) immutable(char *) sf_get_string(SNDFILE *, int);
extern (C) int ao_driver_id(const char *);
extern (C) void ao_shutdown();
extern (C) int sf_read_short(SNDFILE *, short *buf, size_t);
extern (C) int ao_play(ao_device *, char *, uint);
extern (C) void ao_close(ao_device *);
extern (C) ao_device *ao_open_live(int, ao_sample_format *, void *);
extern (C) void sf_close(SNDFILE *);

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

/////

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
    void dumpStruct(Socket s, T v) {
        static foreach (t; __traits(allMembers, T)) {
            static if ((cast(int[])[__traits(getAttributes, __traits(getMember, T, t))]).canFind(dump))
                s.send(format!"%s: %s\n"(t.capitalize(), to!string(__traits(getMember, v, t))));
        }
    }
}

void sendError(Socket s, string msg, uint lineno = 0, Ack ack = Ack.ERROR_UNKNOWN) {
    s.send(format!"ACK [%u@%u] {} %s\n"(ack, lineno, msg));
}

immutable string root = "/home/nc/mus/";

Track makeTrack(string path) {
    Track newTrack;

    SF_INFO i;
    SNDFILE *sfdata = sf_open(toStringz(path), SFM_READ, &i);
    scope (exit) sf_close(sfdata);

    enforce(sfdata != null, "failed to add file");

    newTrack.duration = framesToSeconds(cast(uint) sf_seek(sfdata, 0, SEEK_END), i);

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

uint framesToSeconds(uint frames, SF_INFO i) {
    return frames / i.channels / i.samplerate;
}

uint secondsToFrames(uint seconds, SF_INFO i) {
    return seconds * i.channels * i.samplerate;
}

enum PlayerMessage {QUERY_TRACK, PLAY, PAUSE};

string[] parseCommand(immutable(string) line) pure {
    if(!line.length || line[0] == '\n')
        return [];
    if(line[0] == ' ')
        return parseCommand(line[1..line.length]);
    if(line[0] == '"') {
        long n = line[1..line.length].indexOf('"') + 1;
        enforce(n != 0, "unmatched quote in command");
        return [line[1..n]] ~ parseCommand(line[n+1..line.length]);
    }
    long n = line.indexOfAny(" \n");
    if(n == -1)
        n = line.length;
    return line[0..n] ~ parseCommand(line[n..line.length]);
}


void main() {
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

            status.current.time = framesToSeconds(pos, i);

            if(ao_play(device, cast(char *) buffer.ptr, cast(uint) (read * short.sizeof)) == 0) {
                throw new Exception("ao_play failed");
            }

            Fiber.yield();
        }
    }

    /*task({
            while(true) {
                stats.uptime++;
                if(status.state == State.PLAY) {
                    stats.playtime++;
                }

                Thread.sleep(1.seconds);
            }
    }).executeInNewThread();*/

    Fiber player;

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

    void next() {
        if(status.current + 1 < playlist.ptr + (playlist.length * Track.sizeof))
            play(status.current + 1);
    }

    void seek(int seconds, bool relative) {
        if(relative) {
            sf_seek(file, secondsToFrames(seconds, i), SEEK_CUR);
        } else {
            sf_seek(file, secondsToFrames(seconds, i), SEEK_SET);
        }
    }

    Socket socket = new TcpSocket();
    socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    socket.bind(new InternetAddress(6601));
    socket.listen(5);

    Socket[] clients;

    void handleCommand(Socket c, char[256] input) {
        long n = input.indexOf('\n');
        if(n == -1) {
            // malformed, or empty input
            return;
        }
        string[] command = parseCommand(input[0..n+1].text());
        if(!command.length)
            return;
        writeln(command);
        switch(command[0]) {
            // querying
            case "status":
                c.dumpStruct!Status(status);
                break;
            case "stats":
                c.dumpStruct!Stats(stats);
                break;
            case "currentsong":
                if(status.current)
                    c.dumpStruct!Track(*status.current);
                break;

                // playback control
            case "play":
                uint pos = 0;
                if(command.length > 1)
                    pos = to!uint(command[1]);

                if(playlist.length > 1)
                    play(&playlist[pos]);
                break;

            case "seek":
                uint songpos = to!uint(command[1]);
                enforce(&playlist[songpos] == status.current, "unsupported: seeking a song that's not the current one");
                seek(to!int(command[1]), false);
                break;

            case "seekid":
                uint songid = to!uint(command[1]);
                enforce(status.current.id == songid, "unsupported: seeking a song that's not the current one");
                seek(to!int(command[1]), false);
                break;

            case "seekcur":
                seek(to!int(command[1]), command[1][0] == '-' || command[1][0] == '+');
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
                next();
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
                playlist.each!(a => c.dumpStruct!Track(a));
                break;

            case "plchanges":
                playlist.each!(a => c.dumpStruct!Track(a));
                break;

            case "outputs":
                c.send("outputid: 0\n");
                c.send("outputname: pulseaudio\n");
                c.send("outputenabled: 1\n");
                break;

            case "decoders":
                c.send("plugin: sndfile");
                immutable string[] formats = [
                    "ogg", "flac", "wav", "aiff", "aifc", "snd", "raw", "paf",
                    "iff", "svx", "sf", "voc", "w64", "mat4", "mat5", "pvf", "xi",
                    "htk", "caf", "sd2"
                ];
                foreach(f; formats) {
                    c.send(format!"suffix: %s\n"(formats));
                }
                foreach(f; formats) {
                    c.send(format!"mime_type: audio/%s\n"(formats));
                }
                break;

            case "command_list_begin":
            case "command_list_ok_begin":
                char[] s = strip(fromStringz(input.ptr));
                foreach(i, l; s.split("\n").drop(1).enumerate(0)) {
                    if(l == "command_list_end") {
                        break;
                    }
                    try {
                        // XXX this might overflow
                        char[input.length] m;
                        m[0..l.length] = l;
                        m[l.length] = '\n';

                        handleCommand(c, m);
                        if(command[0] == "command_list_ok_begin")
                            c.send("list_OK\n");
                    } catch(Exception e) {
                        c.sendError(e.msg, i);
                        if(command[0] == "command_list_begin")
                            break;
                    }
                }
                break;
            default:
                writeln("unknown: ", command);
                throw new Exception("unknown command");
        }
    }

    static void listenForClients(shared(Socket) serverSocket) {
        Socket ss = cast(Socket) serverSocket;
        while(true) {
            Socket s = ss.accept();
            ownerTid.send!(shared(Socket))(cast(shared(Socket)) s);
        }
    }

    static void listenToClient(shared(Socket) c) {
        Socket s = cast(Socket) c;
        s.send("OK MPD 0.20.0\n");
        s.blocking = true;
        while(true) {
            char[256] input;
            if(!s.receive(input))
                break;
            ownerTid.send!(shared(Socket), char[256])(c, input);
        }
        s.shutdown(SocketShutdown.BOTH);
        s.close();
    }

    auto socketGetter = spawn(&listenForClients, cast(shared(Socket)) socket);

    // main loop
    while(true) {
        if(status.state == State.PLAY) {
            enforce(status.current);
            player.call();
            if(player.state == Fiber.State.TERM)
                next();
        }

        auto handlers = tuple((shared(Socket) c) => spawn(&listenToClient, c),
                              (shared(Socket) s, char[256] msg) {
                                  Socket c = cast(Socket) s;
                                  try {
                                      handleCommand(c, msg);
                                      c.send("OK\n");
                                  } catch (Exception e) {
                                      c.sendError(e.msg);
                                  }
                              });

        if(status.state == State.PLAY)
            receiveTimeout(-1.seconds, handlers[0], handlers[1]);
        else
            receive(handlers[0], handlers[1]);
    }

    ao_shutdown();
}
