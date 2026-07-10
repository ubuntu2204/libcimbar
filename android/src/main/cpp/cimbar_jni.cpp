// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/**
 * cimbar_jni.cpp — JNI bridge between Android Kotlin and libcimbar C++ API.
 *
 * This file implements the native methods declared in LibcimbarPlugin.kt.
 * It wraps the same C API used by the WASM build (cimbar_js.h / cimbar_recv_js.h),
 * adapting the function signatures for JNI calling conventions.
 *
 * Build: compiled as part of libcimbar_jni.so via android/src/main/cpp/CMakeLists.txt
 */

#include <jni.h>
#include <android/log.h>
#include <cstring>
#include <vector>
#include <string>

// Include the libcimbar C API headers
#include "cimbar_js/cimbar_js.h"
#include "cimbar_js/cimbar_recv_js.h"

#define LOG_TAG "CimbarJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─── State ──────────────────────────────────────────────────────

static std::vector<unsigned char> s_frame_buffer;
static int s_frame_width = 0;
static int s_frame_height = 0;

// ─── Encoder JNI methods ────────────────────────────────────────

extern "C" {

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeConfigureEncoder(
    JNIEnv* env, jobject thiz, jint mode_val, jint compression) {
    LOGI("ConfigureEncoder: mode=%d, compression=%d", mode_val, compression);
    return cimbare_configure(mode_val, compression);
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeInitEncode(
    JNIEnv* env, jobject thiz, jstring filename, jint encode_id) {
    const char* fn = env->GetStringUTFChars(filename, nullptr);
    int fnsize = env->GetStringUTFLength(filename);
    int result = cimbare_init_encode(fn, fnsize, encode_id);
    env->ReleaseStringUTFChars(filename, fn);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeEncodeBufsize(
    JNIEnv* env, jobject thiz) {
    return cimbare_encode_bufsize();
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeEncode(
    JNIEnv* env, jobject thiz, jbyteArray buffer, jint size) {
    if (size <= 0) {
        return cimbare_encode(nullptr, 0); // flush
    }
    jbyte* buf = env->GetByteArrayElements(buffer, nullptr);
    int result = cimbare_encode(reinterpret_cast<const unsigned char*>(buf), size);
    env->ReleaseByteArrayElements(buffer, buf, JNI_ABORT);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeNextFrame(
    JNIEnv* env, jobject thiz) {
    int frameCount = cimbare_next_frame(false);
    if (frameCount > 0) {
        // Extract frame data
        unsigned char* ptr = nullptr;
        int bufSize = cimbare_get_frame_buff(&ptr);
        if (bufSize > 0 && ptr != nullptr) {
            s_frame_buffer.assign(ptr, ptr + bufSize);
            // Calculate dimensions: bufSize = w * h * 3 (RGB)
            int totalPixels = bufSize / 3;
            s_frame_width = static_cast<int>(std::sqrt(totalPixels));
            s_frame_height = totalPixels / s_frame_width;
        }
    }
    return frameCount;
}

JNIEXPORT jbyteArray JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeGetFrameBuff(
    JNIEnv* env, jobject thiz) {
    if (s_frame_buffer.empty()) return nullptr;
    jbyteArray result = env->NewByteArray(s_frame_buffer.size());
    env->SetByteArrayRegion(result, 0, s_frame_buffer.size(),
        reinterpret_cast<const jbyte*>(s_frame_buffer.data()));
    return result;
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeGetFrameWidth(
    JNIEnv* env, jobject thiz) {
    return s_frame_width;
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeGetFrameHeight(
    JNIEnv* env, jobject thiz) {
    return s_frame_height;
}

// ─── Decoder JNI methods ────────────────────────────────────────

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeConfigureDecoder(
    JNIEnv* env, jobject thiz, jint mode_val) {
    LOGI("ConfigureDecoder: mode=%d", mode_val);
    return cimbard_configure_decode(mode_val);
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeGetDecodeBufsize(
    JNIEnv* env, jobject thiz) {
    return cimbard_get_bufsize();
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeGetDecompressBufsize(
    JNIEnv* env, jobject thiz) {
    return cimbard_get_decompress_bufsize();
}

// Temporary decode buffer (allocated once)
static std::vector<unsigned char> s_decode_buffer;
static bool s_decode_buffer_init = false;

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeScanExtractDecode(
    JNIEnv* env, jobject thiz,
    jbyteArray img_data, jint img_w, jint img_h, jint format) {

    if (!s_decode_buffer_init) {
        int bufSize = cimbard_get_bufsize();
        s_decode_buffer.resize(bufSize);
        s_decode_buffer_init = true;
    }

    jbyte* imgBuf = env->GetByteArrayElements(img_data, nullptr);
    int imgLen = env->GetArrayLength(img_data);

    int result = cimbard_scan_extract_decode(
        reinterpret_cast<const unsigned char*>(imgBuf),
        img_w, img_h, format,
        s_decode_buffer.data(), s_decode_buffer.size()
    );

    env->ReleaseByteArrayElements(img_data, imgBuf, JNI_ABORT);
    return result;
}

JNIEXPORT jlong JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeFountainDecode(
    JNIEnv* env, jobject thiz, jbyteArray buffer, jint size) {
    jbyte* buf = env->GetByteArrayElements(buffer, nullptr);
    int64_t result = cimbard_fountain_decode(
        reinterpret_cast<const unsigned char*>(buf), size);
    env->ReleaseByteArrayElements(buffer, buf, JNI_ABORT);
    return static_cast<jlong>(result);
}

JNIEXPORT jint JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeGetFilesize(
    JNIEnv* env, jobject thiz, jint id) {
    return cimbard_get_filesize(static_cast<uint32_t>(id));
}

JNIEXPORT jstring JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeGetFilename(
    JNIEnv* env, jobject thiz, jint id) {
    char filename[256] = {0};
    int len = cimbard_get_filename(static_cast<uint32_t>(id), filename, 256);
    if (len <= 0) return env->NewStringUTF("");
    return env->NewStringUTF(filename);
}

JNIEXPORT jbyteArray JNICALL
Java_com_libcimbar_plugin_LibcimbarPlugin_nativeDecompressRead(
    JNIEnv* env, jobject thiz, jint id) {
    int bufSize = cimbard_get_decompress_bufsize();
    std::vector<unsigned char> buffer(bufSize);

    int bytesRead = cimbard_decompress_read(
        static_cast<uint32_t>(id), buffer.data(), bufSize);

    if (bytesRead <= 0) return nullptr;

    jbyteArray result = env->NewByteArray(bytesRead);
    env->SetByteArrayRegion(result, 0, bytesRead,
        reinterpret_cast<const jbyte*>(buffer.data()));
    return result;
}

} // extern "C"
