// decode-remote-opus.c
//
// Decodes Opus frames produced by extract-remote-opus.swift to a mono WAV.
//
// Input format:
//   Repeated <u16 BE opus_length><opus_payload>
//
// Build:
//   clang Tools/decode-remote-opus.c -lopus -I/opt/homebrew/include \
//     -L/opt/homebrew/lib -o /tmp/decode-remote-opus
//
// Run:
//   /tmp/decode-remote-opus /tmp/iremote-remote-opus.bin /tmp/iremote-remote.wav

#include <opus/opus.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_RATE 16000
#define CHANNELS 1
#define MAX_FRAME_BYTES 4096
#define MAX_FRAME_PCM 5760

static void put_u16_le(FILE *f, uint16_t v) {
    unsigned char b[2] = { (unsigned char)(v & 0xff), (unsigned char)((v >> 8) & 0xff) };
    fwrite(b, 1, 2, f);
}

static void put_u32_le(FILE *f, uint32_t v) {
    unsigned char b[4] = {
        (unsigned char)(v & 0xff),
        (unsigned char)((v >> 8) & 0xff),
        (unsigned char)((v >> 16) & 0xff),
        (unsigned char)((v >> 24) & 0xff)
    };
    fwrite(b, 1, 4, f);
}

static void write_wav_header(FILE *f, uint32_t sample_count) {
    uint32_t data_bytes = sample_count * CHANNELS * 2;
    fwrite("RIFF", 1, 4, f);
    put_u32_le(f, 36 + data_bytes);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f);
    put_u32_le(f, 16);
    put_u16_le(f, 1);
    put_u16_le(f, CHANNELS);
    put_u32_le(f, SAMPLE_RATE);
    put_u32_le(f, SAMPLE_RATE * CHANNELS * 2);
    put_u16_le(f, CHANNELS * 2);
    put_u16_le(f, 16);
    fwrite("data", 1, 4, f);
    put_u32_le(f, data_bytes);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <opus-frames.bin> <out.wav>\n", argv[0]);
        return 2;
    }

    FILE *in = fopen(argv[1], "rb");
    if (!in) {
        perror("open input");
        return 1;
    }

    FILE *tmp = tmpfile();
    if (!tmp) {
        perror("tmpfile");
        fclose(in);
        return 1;
    }

    int err = 0;
    OpusDecoder *dec = opus_decoder_create(SAMPLE_RATE, CHANNELS, &err);
    if (!dec || err != OPUS_OK) {
        fprintf(stderr, "opus_decoder_create failed: %s\n", opus_strerror(err));
        fclose(in);
        fclose(tmp);
        return 1;
    }

    unsigned char lenbuf[2];
    unsigned char frame[MAX_FRAME_BYTES];
    opus_int16 pcm[MAX_FRAME_PCM];
    opus_int16 silence[MAX_FRAME_PCM];
    memset(silence, 0, sizeof(silence));

    int total = 0;
    int ok = 0;
    int failed = 0;
    uint32_t samples = 0;

    while (fread(lenbuf, 1, 2, in) == 2) {
        int len = ((int)lenbuf[0] << 8) | (int)lenbuf[1];
        if (len <= 0 || len > MAX_FRAME_BYTES) {
            fprintf(stderr, "bad frame length %d at frame %d\n", len, total + 1);
            break;
        }
        if (fread(frame, 1, len, in) != (size_t)len) break;
        total++;

        int expected = opus_packet_get_nb_samples(frame, len, SAMPLE_RATE);
        if (expected <= 0 || expected > MAX_FRAME_PCM) {
            expected = 640;
        }

        int decoded = opus_decode(dec, frame, len, pcm, MAX_FRAME_PCM, 0);
        if (decoded > 0) {
            fwrite(pcm, sizeof(opus_int16), decoded, tmp);
            samples += (uint32_t)decoded;
            ok++;
        } else {
            fwrite(silence, sizeof(opus_int16), expected, tmp);
            samples += (uint32_t)expected;
            failed++;
            if (failed <= 5) {
                fprintf(stderr, "frame %d len=%d: %s\n", total, len, opus_strerror(decoded));
            }
            opus_decoder_ctl(dec, OPUS_RESET_STATE);
        }
    }

    FILE *out = fopen(argv[2], "wb");
    if (!out) {
        perror("open output");
        opus_decoder_destroy(dec);
        fclose(in);
        fclose(tmp);
        return 1;
    }

    write_wav_header(out, samples);
    rewind(tmp);
    unsigned char copybuf[8192];
    size_t n = 0;
    while ((n = fread(copybuf, 1, sizeof(copybuf), tmp)) > 0) {
        fwrite(copybuf, 1, n, out);
    }

    fprintf(stderr, "frames=%d decoded=%d failed=%d duration=%.2fs output=%s\n",
            total, ok, failed, (double)samples / SAMPLE_RATE, argv[2]);

    opus_decoder_destroy(dec);
    fclose(in);
    fclose(tmp);
    fclose(out);
    return ok > 0 ? 0 : 1;
}
