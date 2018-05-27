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
import std.algorithm.sorting;
import std.file;
import std.exception;
import std.conv;
import std.typecons;
import std.socket;
import core.thread;
import core.time;
import std.random;
import std.math;

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

extern (C) void ao_initialize();
extern (C) SNDFILE *sf_open(const char *, int, SF_INFO *);
extern (C) int64_t sf_seek(SNDFILE *, int64_t, int);
extern (C) immutable(char *) sf_get_string(SNDFILE *, int);
extern (C) int ao_driver_id(const char *);
extern (C) void ao_shutdown();
extern (C) int sf_readf_short(SNDFILE *, short *buf, size_t);
extern (C) int ao_play(ao_device *, char *, uint);
extern (C) void ao_close(ao_device *);
extern (C) ao_device *ao_open_live(int, ao_sample_format *, void *);
extern (C) void sf_close(SNDFILE *);

ao_device *openDevice(TrackMeta m, int driver) {
    ao_device *device;
    device = ao_open_live(driver, &m.format, null);

    enforce(device != null, "error opening device");
    return device;
}

/////

const enum State {play, stop, pause};

const enum dump = 1; // dump attribute for dumpStruct
const enum dumpc = 2; // dump attribute capitalized

struct Status {
    Track *track;
    int current = -1;
    @dump {
        uint volume = 100;
        bool repeat = false;
        bool random = false;
        bool single = false;
        bool consume = false;
        uint playlist;
        uint playlistlength;
        State state = State.stop;
        uint song;
        uint songid;
        uint nextsong;
        uint nextsongid;
        @property float elapsed() {
            if(track)
                return track.elapsed;
            else
                return 0;
        };
        @property string time() {
            return to!string(round(this.elapsed)) ~ ":" ~ to!string(round(this.duration));
        }

        @property float duration() {
            if(track)
                return track.duration;
            else
                return 0;
        };
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

struct TrackMeta {
    @dump string file;
    @dumpc {
        DateTime last_modified;
        string artist;
        string album;
        string title;
        uint track;
        string genre;
        string date;
        string composer = "";
        uint disc = 1;
        string album_artist = "";
        @property uint time() {
            return cast(uint) round(this.duration);
        }
    }
    @dump float duration;
    @dumpc uint id;
    float elapsed = 0;

    // low level metadata information
    size_t framesize; // framesize in bytes
    ssize_t nframes = 32; // number of frames to grab at once
    ao_sample_format format;
};

// lifted from libmpg123
extern (C) void mpg123_init();
extern (C) void mpg123_exit();
extern struct mpg123_handle;
extern (C) mpg123_handle *mpg123_new(void *, int *);
extern (C) size_t mpg123_outblock(mpg123_handle *);
extern (C) void mpg123_open(mpg123_handle *, const char *);
extern (C) void mpg123_getformat(mpg123_handle *, long *, int *, int *);
extern (C) int mpg123_read(mpg123_handle *, char *, size_t, size_t *);
extern (C) int mpg123_encsize(int);
extern (C) int mpg123_seek(mpg123_handle *, int, int);
extern (C) int mpg123_id3(mpg123_handle *, mpg123_id3v1 **, mpg123_id3v2**);
extern (C) int mpg123_info(mpg123_handle *, mpg123_frameinfo *);
extern (C) void mpg123_close(mpg123_handle *);
extern (C) void mpg123_delete(mpg123_handle *);

struct mpg123_string {
        char* p;
        size_t size;
        size_t fill;
};

struct mpg123_text;
struct mpg123_picture;

struct mpg123_id3v1 {
        char[3] tag;         /**< Always the string "TAG", the classic intro. */
        char[30] title;      /**< Title string.  */
        char[30] artist;     /**< Artist string. */
        char[30] album;      /**< Album string. */
        char[4] year;        /**< Year string. */
        char[30] comment;    /**< Comment string. */
        char genre; /**< Genre index. */
};

struct mpg123_id3v2 {
        char ver;
        mpg123_string *title;
        mpg123_string *artist;
        mpg123_string *album;
        mpg123_string *year;
        mpg123_string *genre;
        mpg123_string *comment;
        mpg123_text    *comment_list; /**< Array of comments. */
        size_t          comments;     /**< Number of comments. */
        mpg123_text    *text;         /**< Array of ID3v2 text fields (including USLT) */
        size_t          texts;        /**< Numer of text fields. */
        mpg123_text    *extra;        /**< The array of extra (TXXX) fields. */
        size_t          extras;       /**< Number of extra text (TXXX) fields. */
        mpg123_picture  *picture;     /**< Array of ID3v2 pictures fields (APIC). */
        size_t           pictures;    /**< Number of picture (APIC) fields. */
};

struct mpg123_frameinfo {
	uint ver;	/**< The MPEG version (1.0/2.0/2.5). */
	int layer;						/**< The MPEG Audio Layer (MP1/MP2/MP3). */
	long rate; 						/**< The sampling rate in Hz. */
	uint mode;			/**< The audio mode (Mono, Stereo, Joint-stero, Dual Channel). */
	int mode_ext;					/**< The mode extension bit flag. */
	int framesize;					/**< The size of the frame (in bytes, including header). */
	uint flags;		/**< MPEG Audio flag bits. Just now I realize that it should be declared as int, not enum. It's a bitwise combination of the enum values. */
	int emphasis;					/**< The emphasis type. */
	int bitrate;					/**< Bitrate of the frame (kbps). */
	int abr_rate;					/**< The target average bitrate. */
	uint vbr;			/**< The VBR mode. */
};

const enum MPG123_OK = 0;
const enum MPG123_DONE = -12;

struct MpegTrack {
    static extensions = [".mpeg", ".mp3"];
    TrackMeta meta;
    mpg123_handle *mh;

    alias meta this;
}

struct SndfileTrack {
    static extensions = [".flac", ".ogg"];
    TrackMeta meta;
    SNDFILE *sfile;

    alias meta this;
}

struct Track {
    static enum Type {MpegTrack, SndfileTrack};
    Type type;
    union U {
        TrackMeta meta;
        SndfileTrack sndfile;
        MpegTrack mpeg;
        alias meta this;
    };
    U u;
    alias u this;
}

Track open(string path) {
    Track r;
    if(MpegTrack.extensions.canFind(path.extension)) {
        const int bits = 8;

        MpegTrack t;

        int err;
        t.mh = mpg123_new(null, &err);
        enforce(t.mh, format!"failed to obtain mpg123 handle. Error: %d"(err));

        mpg123_open(t.mh, toStringz(path));

        mpg123_frameinfo i;
        enforce(mpg123_info(t.mh, &i) == MPG123_OK);

        t.framesize = i.framesize;

        long rate;
        int channels, encoding;
        mpg123_getformat(t.mh, &rate, &channels, &encoding);

        // format
        t.format.bits = mpg123_encsize(encoding) * bits;
        t.format.rate = cast(int) rate;
        t.format.channels = channels;
        t.format.byte_format = AO_FMT_NATIVE;
        t.format.matrix = null;

        // meta
        mpg123_id3v1 *v1;
        mpg123_id3v2 *v2;

        if(v1 && v2) {
            mpg123_id3(t.mh, &v1, &v2);

            t.artist = fromStringz(v1.artist.ptr).dup;
            t.album = fromStringz(v1.album.ptr).dup;
            t.title = fromStringz(v1.title.ptr).dup;

            // apparently comment[29] is the track number in id3v1.1
            t.track = to!uint(v1.comment[29]);
            //track.genre = fromStringz(...).dup;
            t.date = v1.year[0..4].dup;
        }

        r.type = Track.Type.MpegTrack;
        r.mpeg = t;
    } else if (SndfileTrack.extensions.canFind(path.extension)) {
        SndfileTrack t;

        SF_INFO info;
        t.sfile = sf_open(toStringz(path), SFM_READ, &info);
        enforce(t.sfile != null, format!"failed to read file %s"(path));

        // format
        switch (info.format & SF_FORMAT_SUBMASK) {
            case SF_FORMAT_PCM_16:
                t.format.bits = 16;
                break;
            case SF_FORMAT_PCM_24:
                t.format.bits = 24;
                break;
            case SF_FORMAT_PCM_32:
                t.format.bits = 32;
                break;
            case SF_FORMAT_PCM_S8:
                t.format.bits = 8;
                break;
            case SF_FORMAT_PCM_U8:
                t.format.bits = 8;
                break;
            default:
                t.format.bits = 16;
                break;
        }

        t.format.channels = info.channels;
        t.format.rate = info.samplerate;
        t.format.byte_format = AO_FMT_NATIVE;
        t.format.matrix = null;

        t.framesize = 2;

        // meta
        t.artist = fromStringz(sf_get_string(t.sfile, SF_STR_ARTIST)).dup;
        t.album = fromStringz(sf_get_string(t.sfile, SF_STR_ALBUM)).dup;
        t.title = fromStringz(sf_get_string(t.sfile, SF_STR_TITLE)).dup;
        t.track = to!uint(fromStringz(sf_get_string(t.sfile, SF_STR_TRACKNUMBER)));
        t.genre = fromStringz(sf_get_string(t.sfile, SF_STR_GENRE)).dup;
        t.date = fromStringz(sf_get_string(t.sfile, SF_STR_DATE)).dup;

        r.type = Track.Type.SndfileTrack;
        r.sndfile = t;
    } else {
        throw new Exception(format!"unknown extension for %s"(path));
    }

    // shared meta
    r.file = path;
    r.duration = r.seek(0, SEEK_END);
    r.seek(0, SEEK_SET);
    r.last_modified = cast(DateTime) path.timeLastModified;

    enforce(r.framesize, "must set a framesize for every format");
    return r;
}

void close(ref Track *t) {
    final switch(t.type) {
        case Track.Type.MpegTrack:
            mpg123_close(t.mpeg.mh);
            mpg123_delete(t.mpeg.mh);
            break;
        case Track.Type.SndfileTrack:
            sf_close(t.sndfile.sfile);
            break;
    }
    t = null;
}

float seek(ref Track t, float seconds, int whence) {
    t.elapsed = seconds;
    final switch(t.type) {
        case Track.Type.MpegTrack:
            return t.framesToSeconds(mpg123_seek(t.mpeg.mh, t.secondsToOffset(seconds), whence));
        case Track.Type.SndfileTrack:
            return t.framesToSeconds(cast(uint) sf_seek(t.sndfile.sfile, t.secondsToOffset(seconds), whence));
    }
}

// returns is_done, seconds played
Tuple!(bool, float) playChunk(ao_device *device, Track t) {
    char[] buf = new char[t.framesize * t.nframes];
    int frames;
    size_t bytesRead;

    final switch(t.type) {
        case Track.Type.MpegTrack:
            int err = mpg123_read(t.mpeg.mh, buf.ptr, buf.length, &bytesRead);
            frames = cast(int) (bytesRead / t.framesize / t.format.channels);
            if(err == MPG123_DONE) {
                return tuple(true, 0.0f);
            }
            enforce(err == MPG123_OK, format!"failed to read mp3: got error code %d"(err));
            break;
        case Track.Type.SndfileTrack:
            frames = sf_readf_short(t.sndfile.sfile, cast(short *) buf.ptr, t.nframes);
            bytesRead = cast(size_t) frames * t.framesize * t.format.channels;
            break;
    }

    float seconds = t.framesToSeconds(frames);

    if(bytesRead == 0) {
        return tuple(true, 0.0f);
    }

    ao_play(device, buf.ptr, cast(uint) bytesRead);
    return tuple(false, seconds);
}

TrackMeta openMeta(string path) {
    Track t = open(path);
    Track *tp = &t;
    scope(exit) close(tp);
    return t.meta;
}

template dumpStruct(T) {
    // dump instantiated struct
    void dumpStruct(Socket s, T v) {
        static foreach (t; __traits(allMembers, T)) {
            static if ((cast(int[])[__traits(getAttributes, __traits(getMember, T, t))]).canFind(dump))
                s.send(format!"%s: %s\n"(t, to!string(__traits(getMember, v, t))));
            static if ((cast(int[])[__traits(getAttributes, __traits(getMember, T, t))]).canFind(dumpc))
                s.send(format!"%s: %s\n"(t.tr("_", "-").capitalize(), to!string(__traits(getMember, v, t))));
        }
    }
}

void sendError(Socket s, string msg, uint lineno = 0, Ack ack = Ack.ERROR_UNKNOWN) {
    s.send(format!"ACK [%u@%u] {} %s\n"(ack, lineno, msg));
}

immutable string root = "/home/nc/mus/";

void addToPlaylist(ref TrackMeta[] playlist, TrackMeta t) {
    t.id = cast(uint) playlist.length + 1;
    playlist ~= t;
}

float framesToSeconds(TrackMeta m, uint frames) {
    return cast(float) frames / m.format.rate;
}

uint secondsToOffset(TrackMeta m, float seconds) {
    return cast(uint) (seconds * m.format.channels * m.format.rate * m.framesize);
}

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
    // libao for output
    ao_initialize();
    scope(exit) ao_shutdown();

    // init libmpg123
    mpg123_init();
    scope(exit) mpg123_exit();

    int driver = ao_driver_id(toStringz("pulse"));
    assert(driver != -1);

    Status status;
    Stats stats;

    // TODO scan library and populate artists, albums and tracks

    TrackMeta[] queue;

    // %%%
    ao_device *device;

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

    void play(uint i) {
        status.current = i;

        // cleanup previous device
        if(device) {
            if(status.track) {
                close(status.track);
            }

            ao_close(device);
            device = null;
        }

        Track cur = open(queue[i].file);
        status.track = &cur;
        device = openDevice(cur, driver);

        if(player) player.destroy();

        player = new Fiber({
                    while(true) {
                        Tuple!(bool, float) r = playChunk(device, cur);
                        bool isDone = r[0];
                        if(isDone)
                            return;
                        cur.elapsed += r[1];
                        Fiber.yield();
                    }
                });

        status.state = State.play;
    }

    void next() {
        if(status.current < queue.length - 1)
            status.current++;
        play(status.current);
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
                if(status.track)
                    c.dumpStruct!TrackMeta(*status.track);
                break;

                // playback control
            case "play":
                uint pos = 0;
                if(command.length > 1)
                    pos = min(to!uint(command[1]), command.length - 1);

                if(queue.length > 1)
                    play(pos);
                break;

            case "seek":
                float songpos = to!float(command[1]);
                enforce(songpos == status.current, "unsupported: seeking a song that's not the current one");
                (*status.track).seek(songpos, SEEK_SET);
                break;

            case "seekid":
                enforce(command.length == 3);
                uint songid = to!uint(command[1]);
                float pos = to!float(command[2]);
                enforce(status.track.id == songid, "unsupported: seeking a song that's not the current one");
                (*status.track).seek(pos, SEEK_SET);
                break;

            case "seekcur":
                (*status.track).seek(to!float(command[1]), (command[1][0] == '-' || command[1][0] == '+') ? SEEK_CUR : SEEK_SET);
                break;

            case "playid":
                int id = to!uint(command[1]);
                foreach(i, track; queue.enumerate()) {
                    if(track.id == id) {
                        play(cast(uint) i);
                        break;
                    }
                }
                break;
            case "stop":
                play(0);
                status.state = State.stop;
                break;

            case "next":
                next();
                break;
            case "previous":
                if(status.current - 1 >= 0)
                    play(status.current - 1);
                break;
            case "pause":
                if(command.length > 1) {
                    if(to!uint(command[1]))
                        status.state = State.pause;
                    else
                        status.state = State.play;
                } else {
                    if(status.state == State.play)
                        status.state = State.pause;
                    else if(status.state == State.pause)
                        status.state = State.play;
                }
                break;

                // playlist
            case "add":
                string p = root ~ command.drop(1).join(" ");

                char[256] msg;
                enforce(p.exists, sformat(msg, "no such file or directory: %s", p));

                if(p.isDir) {
                    foreach(t; p.dirEntries(SpanMode.depth)) {
                        if(t.isDir) continue;
                        writeln("adding", t);
                        try {
                            queue.addToPlaylist(openMeta(t));
                        } catch(Exception e) {
                            writeln(format!"failed to add song: %s"(e.msg));
                        }
                    }
                } else {
                    queue.addToPlaylist(openMeta(p));
                }

                break;
            case "playlistinfo":
                queue.each!(a => c.dumpStruct!TrackMeta(a));
                break;

            case "shuffle":
                bool shouldShuffle = false;
                if(command.length == 1 || (command.length > 1 && command[1] == "1"))
                    shouldShuffle = true;
                if(shouldShuffle)
                    queue.randomShuffle();
                else
                    queue.sort!("a.id < b.id");
                break;

            // other
            case "plchanges":
                queue.each!(a => c.dumpStruct!TrackMeta(a));
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
        if(status.state == State.play) {
            if(player.state == Fiber.State.TERM)
                next();
            player.call();
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

        if(status.state == State.play)
            receiveTimeout(-1.seconds, handlers[0], handlers[1]);
        else
            receive(handlers[0], handlers[1]);
    }
}
