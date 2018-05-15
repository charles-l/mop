struct SNDFILE;
struct ao_device;

// lifted from libao header file

const enum AO_FMT_NATIVE = 4;
struct ao_sample_format {
	int  bits;
	int  rate;
	int  channels;
	int  byte_format;
        char *matrix;
};

// lifted from sndfile header file

const enum SFM_READ = 0x10; // we only every read, so this is the only enum value we need
struct SF_INFO {
    long	    frames ;
	int			samplerate ;
	int			channels ;
	int			format ;
	int			sections ;
	int			seekable ;
}

enum
{
    /* Subtypes from here on. */

	SF_FORMAT_PCM_S8		= 0x0001,		/* Signed 8 bit data */
	SF_FORMAT_PCM_16		= 0x0002,		/* Signed 16 bit data */
	SF_FORMAT_PCM_24		= 0x0003,		/* Signed 24 bit data */
	SF_FORMAT_PCM_32		= 0x0004,		/* Signed 32 bit data */

	SF_FORMAT_PCM_U8		= 0x0005,		/* Unsigned 8 bit data (WAV and RAW only) */

	SF_FORMAT_SUBMASK		= 0x0000FFFF,
};

const uint BUFFER_SIZE = 8192;

extern (C) void ao_initialize();
extern (C) SNDFILE *sf_open(const char *f, int, SF_INFO *sfinfo);
extern (C) int ao_driver_id(const char *);
extern (C) void ao_shutdown();
extern (C) int sf_read_short(SNDFILE *, short *buf, size_t);
extern (C) int ao_play(ao_device *, char *, uint);
extern (C) void ao_close(ao_device *);
extern (C) ao_device *ao_open_live(int, ao_sample_format *, void *);
extern (C) void sf_close(SNDFILE *);

import std.string;
import std.path;
import std.parallelism;
import std.stdio;

ao_device *open_device(SNDFILE *f, SF_INFO sfinfo, int driver) {
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

    if (device == null) {
        sf_close(f);
        throw new Exception("error opening device");
    }
    return device;
}

void main() {
    ao_initialize();
    int driver = ao_driver_id(toStringz("pulse"));
    assert(driver != -1);

    short[BUFFER_SIZE * short.sizeof] buffer;
    while(true) {
        string s = chomp(readln);
        writeln("'", s, "' - playing");
        string e = expandTilde(s);
        immutable(char *) c = toStringz(e);
        SF_INFO i;

        SNDFILE *file = sf_open(c, SFM_READ, &i);
        ao_device *device = open_device(file, i, driver);

        int pos;

        while(true) {
            int read = sf_read_short(file, buffer.ptr, BUFFER_SIZE);
            if(!read) {
                break;
            }

            pos += read;

            writeln("position ", pos / i.channels / i.samplerate);

            if(ao_play(device, cast(char *) buffer.ptr, cast(uint) (read * short.sizeof)) == 0) {
                throw new Exception("ao_play failed");
            }
        }

        ao_close(device);
        sf_close(file);
    }
    ao_shutdown();
}
