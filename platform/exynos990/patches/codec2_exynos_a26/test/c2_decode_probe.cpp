// Decodes the first video track of a file with an explicitly named codec and
// reports decoded frames, output format and timing.  Used to validate the
// A26 Exynos Codec2 chain on the Exynos 990 without touching media_codecs.xml.
//
//   c2_decode_probe <file> <codec-name> [max-frames] [rt]
//
// "rt" requests real-time priority (priority=0), as the Samsung Gallery does.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <file> <codec-name> [max-frames]\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];
    const char* name = argv[2];
    long maxFrames = argc > 3 ? strtol(argv[3], nullptr, 10) : 300;
    bool realTime = argc > 4 && strcmp(argv[4], "rt") == 0;

    int fd = open(path, O_RDONLY);
    struct stat st = {};
    if (fd < 0 || fstat(fd, &st) != 0) {
        perror("open");
        return 1;
    }
    AMediaExtractor* ex = AMediaExtractor_new();
    if (AMediaExtractor_setDataSourceFd(ex, fd, 0, st.st_size) != AMEDIA_OK) {
        fprintf(stderr, "extractor: setDataSource failed\n");
        return 1;
    }
    AMediaFormat* fmt = nullptr;
    for (size_t i = 0; i < AMediaExtractor_getTrackCount(ex); ++i) {
        AMediaFormat* f = AMediaExtractor_getTrackFormat(ex, i);
        const char* mime = nullptr;
        if (AMediaFormat_getString(f, AMEDIAFORMAT_KEY_MIME, &mime) && strncmp(mime, "video/", 6) == 0) {
            AMediaExtractor_selectTrack(ex, i);
            fmt = f;
            break;
        }
        AMediaFormat_delete(f);
    }
    if (fmt == nullptr) {
        fprintf(stderr, "no video track\n");
        return 1;
    }
    printf("input format: %s\n", AMediaFormat_toString(fmt));

    auto t0 = std::chrono::steady_clock::now();
    AMediaCodec* codec = AMediaCodec_createCodecByName(name);
    if (codec == nullptr) {
        fprintf(stderr, "createCodecByName(%s) failed\n", name);
        return 1;
    }
    char* actual = nullptr;
    if (AMediaCodec_getName(codec, &actual) == AMEDIA_OK) {
        printf("codec: %s\n", actual);
        AMediaCodec_releaseName(codec, actual);
    }
    if (realTime) {
        AMediaFormat_setInt32(fmt, "priority", 0);
    }
    media_status_t err = AMediaCodec_configure(codec, fmt, nullptr, nullptr, 0);
    if (err != AMEDIA_OK) {
        fprintf(stderr, "configure failed: %d\n", err);
        return 1;
    }
    if ((err = AMediaCodec_start(codec)) != AMEDIA_OK) {
        fprintf(stderr, "start failed: %d\n", err);
        return 1;
    }
    auto t1 = std::chrono::steady_clock::now();

    bool inputDone = false;
    bool outputDone = false;
    long frames = 0;
    long nonZero = 0;
    int idle = 0;
    while (!outputDone && idle < 200) {
        if (!inputDone) {
            ssize_t in = AMediaCodec_dequeueInputBuffer(codec, 10000);
            if (in >= 0) {
                size_t cap = 0;
                uint8_t* buf = AMediaCodec_getInputBuffer(codec, in, &cap);
                ssize_t size = AMediaExtractor_readSampleData(ex, buf, cap);
                if (size < 0 || frames >= maxFrames) {
                    AMediaCodec_queueInputBuffer(codec, in, 0, 0, 0,
                                                 AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
                    inputDone = true;
                } else {
                    int64_t pts = AMediaExtractor_getSampleTime(ex);
                    AMediaCodec_queueInputBuffer(codec, in, 0, size, pts, 0);
                    AMediaExtractor_advance(ex);
                }
            }
        }
        AMediaCodecBufferInfo info = {};
        ssize_t out = AMediaCodec_dequeueOutputBuffer(codec, &info, 10000);
        if (out >= 0) {
            idle = 0;
            if (info.size > 0) {
                size_t cap = 0;
                uint8_t* buf = AMediaCodec_getOutputBuffer(codec, out, &cap);
                if (buf != nullptr) {
                    for (int32_t i = info.offset; i < info.offset + info.size; i += 4093) {
                        if (buf[i] != 0) {
                            ++nonZero;
                            break;
                        }
                    }
                }
                ++frames;
            }
            if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
                outputDone = true;
            }
            AMediaCodec_releaseOutputBuffer(codec, out, false);
        } else if (out == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            AMediaFormat* of = AMediaCodec_getOutputFormat(codec);
            printf("output format: %s\n", AMediaFormat_toString(of));
            AMediaFormat_delete(of);
        } else if (out == AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
            ++idle;
        }
    }
    auto t2 = std::chrono::steady_clock::now();
    using ms = std::chrono::duration<double, std::milli>;
    printf("frames=%ld nonzero=%ld eos=%d setup=%.1fms decode=%.1fms fps=%.1f\n",
           frames, nonZero, outputDone ? 1 : 0, ms(t1 - t0).count(), ms(t2 - t1).count(),
           frames * 1000.0 / ms(t2 - t1).count());
    AMediaCodec_stop(codec);
    AMediaCodec_delete(codec);
    AMediaFormat_delete(fmt);
    AMediaExtractor_delete(ex);
    close(fd);
    return frames > 0 && outputDone ? 0 : 1;
}
