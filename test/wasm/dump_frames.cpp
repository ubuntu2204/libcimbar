// Encode a payload with libcimbar and dump each frame as raw RGB, for the
// headless WASM decoder test in this directory.
//
// Frames are written straight from the encoder's own buffer, so they are
// lossless: any decode failure downstream is a decoder problem, not a
// camera/capture problem. That is what makes this a useful regression test —
// it isolates the WASM build from the web capture chain.
//
// Build: see run.sh
// Usage: dump_frames [input-file] <out-dir> <num-frames>
//        (omit the input file to generate a deterministic test payload)
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

extern "C" {
int cimbare_configure(int modeVal, int compression);
int cimbare_init_encode(const char* filename, unsigned fnsize, int encodeId);
int cimbare_encode_bufsize();
int cimbare_encode(unsigned char* buffer, unsigned size);
int cimbare_next_frame(bool colorBalance);
int cimbare_get_frame_buff(unsigned char** buff);
}

namespace {

// Small LCG so the synthetic payload is identical on every machine/run.
struct Rng {
    unsigned long long s;
    explicit Rng(unsigned long long seed) : s(seed) {}
    unsigned char next() {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned char>((s >> 33) & 0xFF);
    }
};

std::vector<unsigned char> makePayload(size_t n) {
    Rng rng(0xC1BA5EEDULL);
    std::vector<unsigned char> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = rng.next();
    return v;
}

}  // namespace

int main(int argc, char** argv) {
    // argv[1] optional input file; argv[-2] = out dir; argv[-1] = num frames
    if (argc < 3) {
        std::fprintf(stderr,
            "usage: %s [input-file] <out-dir> <num-frames>\n", argv[0]);
        return 2;
    }
    const char* inPath = (argc >= 4) ? argv[1] : nullptr;
    const std::string outDir = argv[argc - 2];
    const int numFrames = std::atoi(argv[argc - 1]);
    if (numFrames <= 0) {
        std::fprintf(stderr, "num-frames must be > 0\n");
        return 2;
    }

    std::vector<unsigned char> data;
    if (inPath != nullptr) {
        std::ifstream in(inPath, std::ios::binary);
        data.assign((std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
        if (data.empty()) {
            std::fprintf(stderr, "cannot read input: %s\n", inPath);
            return 3;
        }
    } else {
        // ~60 KB compresses to roughly 8-11 cimbar frames at mode B.
        data = makePayload(60 * 1024);
    }

    // mode B == 68, compression 16 (the app defaults)
    if (cimbare_configure(68, 16) < 0) {
        std::fprintf(stderr, "cimbare_configure failed\n");
        return 4;
    }
    const std::string name = "wasm_test_payload.bin";
    if (cimbare_init_encode(name.c_str(),
                            static_cast<unsigned>(name.size()), 0) < 0) {
        std::fprintf(stderr, "cimbare_init_encode failed\n");
        return 5;
    }

    const unsigned cs = static_cast<unsigned>(cimbare_encode_bufsize());
    std::vector<unsigned char> chunk(cs);
    size_t off = 0;
    while (off < data.size()) {
        const unsigned n = (data.size() - off >= cs) ? cs
                         : static_cast<unsigned>(data.size() - off);
        std::memcpy(chunk.data(), data.data() + off, n);
        off += n;
        if (cimbare_encode(chunk.data(), n) < 0) {
            std::fprintf(stderr, "cimbare_encode failed at offset %zu\n", off - n);
            return 6;
        }
        if (off >= data.size()) {
            cimbare_encode(chunk.data(), 0);  // flush
            break;
        }
    }

    int written = 0;
    for (int i = 0; i < numFrames; ++i) {
        if (cimbare_next_frame(false) <= 0) break;
        unsigned char* fb = nullptr;
        const int size = cimbare_get_frame_buff(&fb);
        if (size <= 0 || fb == nullptr) break;

        // size == width*height*3 (RGB). Square, so side = sqrt(size/3).
        int side = 1;
        while (side * side * 3 < size) ++side;
        if (side * side * 3 != size) {
            std::fprintf(stderr,
                "unexpected frame size %d (not a square RGB image)\n", size);
            return 7;
        }

        char path[1024];
        std::snprintf(path, sizeof(path), "%s/frame_%03d.rgb", outDir.c_str(), i);
        std::ofstream out(path, std::ios::binary);
        if (!out) {
            std::fprintf(stderr, "cannot write %s\n", path);
            return 8;
        }
        out.write(reinterpret_cast<const char*>(fb), size);
        ++written;
    }

    if (written == 0) {
        std::fprintf(stderr, "encoder produced no frames\n");
        return 9;
    }
    std::printf("wrote %d frames, %zu-byte payload\n", written, data.size());
    return 0;
}
