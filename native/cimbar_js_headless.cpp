// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Headless encoder wrapper - replaces cimbar_js.cpp to avoid GLFW/OpenGL dependency.
// Provides the same extern "C" encoder API but window functions return error codes.

#include "cimbar_js.h"

#include "cimb_translator/Config.h"
#include "compression/zstd_compressor.h"
#include "encoder/Encoder.h"
#include "extractor/Scanner.h"
#include "fountain/FountainInit.h"
#include "fountain/fountain_encoder_stream.h"
#include "util/byte_istream.h"
#include <sstream>
#include <iostream>

namespace {
    std::shared_ptr<fountain_encoder_stream> _fes;
    std::optional<cv::Mat> _next;

    std::unique_ptr<cimbar::zstd_compressor<std::stringstream>> _comp;

    int _frameCount = 0;
    uint8_t _encodeId = 109;

    int _modeVal = 68;
    int _compressionLevel = cimbar::Config::compression_level();
}

extern "C" {

int cimbare_configure(int mode_val, int compression)
{
    if (compression < 0 or compression > 22)
        compression = cimbar::Config::compression_level();

    bool refresh = (mode_val != _modeVal or compression != _compressionLevel);
    if (refresh) {
        _modeVal = mode_val;
        _compressionLevel = compression;
        cimbar::Config::update(_modeVal);
    }
    return 0;
}

int cimbare_init_encode(const char* filename, unsigned fnsize, int encode_id)
{
    _frameCount = 0;
    if (!FountainInit::init()) {
        std::cerr << "failed FountainInit" << std::endl;
        return -5;
    }

    if (encode_id < 0)
        ++_encodeId;
    else
        _encodeId = encode_id;

    _comp = std::make_unique<cimbar::zstd_compressor<std::stringstream>>();
    if (!_comp)
        return -1;

    _comp->set_compression_level(_compressionLevel);

    if (fnsize > 0 and filename != nullptr)
        _comp->write_header(filename, fnsize);

    _fes.reset();
    return 0;
}

int cimbare_encode_bufsize()
{
    return cimbar::zstd_compressor<std::stringstream>::CHUNK_SIZE;
}

int cimbare_encode(const unsigned char* buffer, unsigned size)
{
    if (!_comp) {
        // Already flushed in a previous call (idempotent flush)
        if (_fes and size == 0) {
            return 0;
        }
        std::cerr << "[cimbar] encode: _comp is null! size=" << size << std::endl;
        return -1;
    }

    if (size > 0) {
        if (!_comp->write(reinterpret_cast<const char*>(buffer), size)) {
            std::cerr << "[cimbar] encode: write failed, size=" << size << std::endl;
            return -2;
        }
    }

    int bufsize = cimbare_encode_bufsize();
    if (size > 0 and size % bufsize == 0) {
        return 1; // more to do
    }

    // Ready to finalize
    cimbar::Config::update(_modeVal);
    unsigned fountainChunkSize = cimbar::Config::fountain_chunk_size();
    size_t compressedSize = _comp->size();

    std::cerr << "[cimbar] flush: compressedSize=" << compressedSize
              << ", fountainChunkSize=" << fountainChunkSize
              << ", modeVal=" << _modeVal << std::endl;

    if (fountainChunkSize == 0) {
        std::cerr << "[cimbar] flush: fountainChunkSize is 0!" << std::endl;
        return -4;
    }

    if (compressedSize < fountainChunkSize)
        _comp->pad(fountainChunkSize - compressedSize + 1);

    _fes = fountain_encoder_stream::create(*_comp, fountainChunkSize, _encodeId);
    _comp.reset();
    if (!_fes) {
        std::cerr << "[cimbar] flush: fountain_encoder_stream::create failed!" << std::endl;
        return -3;
    }

    _next.reset();
    std::cerr << "[cimbar] flush: success" << std::endl;
    return 0;
}

int cimbare_next_frame(bool color_balance)
{
    if (!_fes)
        return -1;

    // Calculate how many frames we need: blocks_required * 2 for redundancy,
    // minimum 8 frames for small files
    unsigned blocksNeeded = _fes->blocks_required();
    unsigned maxFrames = blocksNeeded * 2;
    if (maxFrames < 8) maxFrames = 8;
    if (maxFrames > 200) maxFrames = 200; // hard cap

    // Stop after generating enough frames
    if ((unsigned)_frameCount >= maxFrames) {
        std::cerr << "[cimbar] next_frame: DONE, " << _frameCount
                  << "/" << maxFrames << " frames (blocks=" << blocksNeeded << ")" << std::endl;
        return 0;
    }

    if (_frameCount == 0) {
        std::cerr << "[cimbar] next_frame: starting, blocks=" << blocksNeeded
                  << ", maxFrames=" << maxFrames << std::endl;
    }

    Encoder enc;
    if (color_balance)
        enc.set_color_mode(cimbar::Config::color_mode() + 0x100);
    enc.set_encode_id(_encodeId);

    std::cerr << "[cimbar] next_frame: generating frame " << (_frameCount + 1) << "..." << std::endl;
    _next = enc.encode_next(*_fes, cimbar::vec_xy{});
    if (!_next.has_value()) {
        std::cerr << "[cimbar] next_frame: encode_next returned empty!" << std::endl;
        return -1;
    }
    ++_frameCount;
    std::cerr << "[cimbar] next_frame: frame " << _frameCount << " OK ("
              << _next->cols << "x" << _next->rows << ")" << std::endl;
    return _frameCount;
}

int cimbare_get_frame_buff(unsigned char** buff)
{
    if (!_next)
        return -2;
    if (_next->cols == 0 or _next->rows == 0)
        return -1;

    *buff = _next->data;
    return _next->cols * _next->rows * _next->channels();
}

// Whether the frame most recently produced by cimbare_next_frame() would
// survive the decoder's anchor scan.
//
// Upstream's EncoderPlus::encode_fountain() does this and skips the frame,
// with the comment: "some % of generated frames (for the current 8x8 impl)
// will produce random patterns that falsely match as corner anchors and fail
// to extract." The cimbar_js C API has no equivalent, so an app using it
// happily emits frames the decoder can never locate. Measured on a 200-frame
// run: ~1.5% of frames fail this check.
//
// We test the frame still held in `_next` rather than a caller-supplied
// buffer — the caller already has that pointer, and rebuilding a cv::Mat
// from it just to throw it away is pointless.
//
// Returns 1 = scans fine, 0 = would fail to extract, -1 = no frame.
int cimbare_will_it_scan()
{
    if (!_next)
        return -1;
    return Scanner::will_it_scan(*_next) ? 1 : 0;
}

// Window functions - stub for headless mode
int cimbare_init_window(int, int) { return -1; }
int cimbare_rotate_window(bool) { return -1; }
bool cimbare_auto_scale_window(unsigned) { return false; }
float cimbare_get_aspect_ratio() { return 1.0f; }
int cimbare_render() { return -1; }

} // extern "C"
