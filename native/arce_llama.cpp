// ARCE.AI — JNI bridge to llama.cpp (pinned @d81aef1)
// CPU backend always available; Vulkan GPU backend when built with GGML_VULKAN=ON.
// One model at a time. Generation runs on the calling (IO) thread.

#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "llama.h"

#define LOG_TAG "arce_llama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

struct Engine {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    llama_vocab * vocab = nullptr;
    std::atomic<bool> stop{false};

    jobject cbRef = nullptr;
    jmethodID onTokenM = nullptr;
    jmethodID onDoneM = nullptr;

    ~Engine() {
        if (ctx) { llama_free(ctx); ctx = nullptr; }
        if (model) { llama_model_free(model); model = nullptr; }
    }
};

Engine g_engine;

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_arce_ai_ArceLlama_nativeBackends(JNIEnv * env, jobject) {
    std::string out;
    int n = 0;
    GGML_TRY {
        n = ggml_backend_dev_count();
    } catch (const std::exception & e) {
        LOGE("backend enumeration failed: %s", e.what());
    }
    for (int i = 0; i < n; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const char * name = dev ? ggml_backend_dev_name(dev) : "unknown";
        if (!out.empty()) out += ";";
        out += (name && name[0]) ? name : "unknown";
    }
    if (out.empty()) return env->NewStringUTF("none");
    return env->NewStringUTF(out.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_arce_ai_ArceLlama_nativeFreeModel(JNIEnv * env, jobject) {
    Engine & g = g_engine;
    if (g.ctx) { llama_free(g.ctx); g.ctx = nullptr; }
    if (g.model) { llama_model_free(g.model); g.model = nullptr; }
    g.vocab = nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_arce_ai_ArceLlama_nativeInitModel(JNIEnv * env, jobject,
                                           jstring jpath, jint gpuLayers,
                                           jint nCtx, jint threads) {
    Engine & g = g_engine;
    Java_com_arce_ai_ArceLlama_nativeFreeModel(env, nullptr);

    const char * path = env->GetStringUTFChars(jpath, nullptr);
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpuLayers;
    g.model = llama_model_load_from_file(path, mp);
    env->ReleaseStringUTFChars(jpath, path);
    if (!g.model) {
        LOGE("model load failed: %s", path);
        return 1;
    }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = nCtx;
    cp.n_threads = threads;
    g.ctx = llama_init_from_model(g.model, cp);
    if (!g.ctx) {
        LOGE("context init failed (n_ctx=%d)", nCtx);
        llama_model_free(g.model);
        g.model = nullptr;
        return 2;
    }
    g.vocab = llama_model_get_vocab(g.model);
    LOGI("model loaded ctx=%d gpu_layers=%d threads=%d", nCtx, gpuLayers, threads);
    return 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_arce_ai_ArceLlama_nativeStop(JNIEnv * env, jobject) {
    g_engine.stop = true;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_arce_ai_ArceLlama_nativeGenerate(JNIEnv * env, jobject,
                                          jstring jprompt, jint maxTokens,
                                          jfloat temp, jfloat penalty,
                                          jobject cb) {
    Engine & g = g_engine;
    if (!g.ctx || !g.vocab) return 1;

    g.cbRef = env->NewGlobalRef(cb);
    jclass cls = env->GetObjectClass(cb);
    g.onTokenM = env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)V");
    g.onDoneM = env->GetMethodID(cls, "onDone", "(Ljava/lang/String;Ljava/lang/String;)V");
    g.stop = false;

    const char * prompt = env->GetStringUTFChars(jprompt, nullptr);
    int plen = (int) strlen(prompt);

    // tokenize (prompt-only, no special tokens appended; the prompt string
    // already contains the chat template built on the Kotlin side)
    std::vector<llama_token> buf(plen + 8);
    int ntok = llama_tokenize(g.vocab, prompt, plen, buf.data(), (int) buf.size(), true, false);
    env->ReleaseStringUTFChars(jprompt, prompt);
    if (ntok < 0) {
        LOGE("tokenize failed rc=%d", ntok);
        if (g.cbRef) env->CallVoidMethod(g.cbRef, g.onDoneM, env->NewStringUTF(""),
                                         env->NewStringUTF("トークン化に失敗しました"));
        env->DeleteGlobalRef(g.cbRef); g.cbRef = nullptr;
        return 2;
    }
    buf.resize(ntok);

    int rc = llama_decode(g.ctx, llama_batch_get_one(buf.data(), ntok));
    if (rc != 0) {
        LOGE("prompt decode failed rc=%d", rc);
        if (g.cbRef) env->CallVoidMethod(g.cbRef, g.onDoneM, env->NewStringUTF(""),
                                         env->NewStringUTF("プロンプト処理に失敗しました"));
        env->DeleteGlobalRef(g.cbRef); g.cbRef = nullptr;
        return 3;
    }

    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_temp_init(temp));
    llama_sampler_chain_add(smpl, llama_sampler_penalty_init(64, penalty, 0.0f));

    std::string full;
    llama_token prev = buf.empty() ? LLAMA_TOKEN_NULL : buf[ntok - 1];

    for (int i = 0; i < maxTokens; i++) {
        if (g.stop) {
            LOGI("generation stopped by user at %zu chars", full.size());
            break;
        }
        llama_token id = llama_sampler_sample(smpl, g.ctx, prev);
        if (id == LLAMA_TOKEN_NULL || llama_vocab_is_eog(g.vocab, id)) break;

        int drc = llama_decode(g.ctx, llama_batch_get_one(&id, 1));
        if (drc != 0) {
            LOGE("decode failed at token %d rc=%d", i, drc);
            if (g.cbRef) env->CallVoidMethod(g.cbRef, g.onDoneM, env->NewStringUTF(full.c_str()),
                                             env->NewStringUTF("デコード中にエラーが発生しました"));
            llama_sampler_free(smpl);
            env->DeleteGlobalRef(g.cbRef); g.cbRef = nullptr;
            return 4;
        }

        char piecebuf[512];
        int pc = llama_token_to_piece(g.vocab, id, piecebuf, (int) sizeof(piecebuf));
        if (pc > 0) {
            full.append(piecebuf, pc);
            if (g.cbRef) {
                piecebuf[pc] = 0;
                env->CallVoidMethod(g.cbRef, g.onTokenM, env->NewStringUTF(piecebuf));
            }
        }
        prev = id;
    }

    llama_sampler_free(smpl);
    if (g.cbRef) {
        env->CallVoidMethod(g.cbRef, g.onDoneM, env->NewStringUTF(full.c_str()),
                            g.stop ? env->NewStringUTF("stopped") : nullptr);
        env->DeleteGlobalRef(g.cbRef);
    }
    g.cbRef = nullptr;
    g.onTokenM = nullptr;
    g.onDoneM = nullptr;
    return 0;
}
