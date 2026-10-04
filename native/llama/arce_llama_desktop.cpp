// Desktop C ABI bridge. Keep the generation mechanics in sync with the Android JNI bridge.
// JNI bridge between ai.arce.app.engine.LlamaNative and llama.cpp.
//
// One Engine owns a model and a context. A generation is a Session: it holds the sampler
// chain (with an optional lazy GBNF grammar for tool calls) and the per-generation state.
// Only one Session may be active per Engine; the Kotlin side runs all calls except
// nativeCancel on a single thread.

#include <atomic>
#include <cstring>
#include <algorithm>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "ggml-backend.h"
#include "json-schema-to-grammar.h"
#include "json.h"
#include "llama.h"

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "arce-llama", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "arce-llama", __VA_ARGS__)
#else
#include <cstdio>
#define LOGI(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#define LOGE(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#endif

namespace {

// Keep in sync with ai.arce.core.generation.FinishReason
enum FinishReason : int { RUNNING = -1, EOG = 0, LENGTH = 1, CANCELLED = 2, ERROR = 3 };

struct Engine {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    std::atomic<bool> cancel{false};
    // Tokens currently held in the KV cache (sequence 0), in order. The next prompt reuses
    // the longest common prefix instead of re-evaluating the whole conversation.
    std::vector<llama_token> cached;

    ~Engine() {
        if (ctx) llama_free(ctx);
        if (model) llama_model_free(model);
    }
};

struct Session {
    Engine * engine = nullptr;
    llama_sampler * sampler = nullptr;
    int max_tokens = 0;
    int generated = 0;
    int finish = RUNNING;
    std::string utf8_pending;  // bytes of a character split across tokens
    std::string output;        // valid until the next arce_next call

    ~Session() {
        if (sampler) llama_sampler_free(sampler);
    }
};

thread_local std::string g_last_error;

void set_error(const std::string & message) {
    g_last_error = message;
    LOGE("%s", message.c_str());
}

// Length of the longest prefix of s that ends on a complete UTF-8 character.
size_t complete_utf8_prefix(const std::string & s) {
    size_t i = s.size();
    size_t back = 0;
    while (i > 0 && back < 4) {
        const auto c = static_cast<unsigned char>(s[i - 1]);
        if ((c & 0xC0) != 0x80) {  // lead byte or ASCII
            size_t need = 1;
            if ((c & 0xE0) == 0xC0) need = 2;
            else if ((c & 0xF0) == 0xE0) need = 3;
            else if ((c & 0xF8) == 0xF0) need = 4;
            return (back + 1 >= need) ? s.size() : i - 1;
        }
        --i;
        ++back;
    }
    return s.size();
}

bool abort_requested(void * data) {
    return static_cast<Engine *>(data)->cancel.load();
}

// Wraps the tool-call JSON grammar so that the constrained part starts at <tool_call>.
std::string tool_call_grammar(const std::string & schema_json) {
    const std::string body = json_schema_to_grammar(common_json::parse(schema_json));

    // Rename the generated start rule (a line beginning with "root ::=") so ours can take its place.
    // Done by hand: std::regex::multiline is not available in every libc++ the NDK ships.
    std::string renamed;
    size_t line_start = 0;
    while (line_start < body.size()) {
        size_t line_end = body.find('\n', line_start);
        if (line_end == std::string::npos) line_end = body.size();
        std::string line = body.substr(line_start, line_end - line_start);
        if (line.rfind("root ::=", 0) == 0) line = "tool-json ::=" + line.substr(std::strlen("root ::="));
        renamed += line + "\n";
        line_start = line_end + 1;
    }
    return "root ::= \"<tool_call>\" [ \\t\\n]* tool-json [ \\t\\n]* \"</tool_call>\"\n" + renamed;
}

llama_sampler * make_sampler(const llama_model * model, const std::string & tool_schema,
                             const std::string & strict_schema, bool thinking, float temperature, float top_p,
                             int top_k, float min_p, float dry_multiplier) {
    const llama_vocab * vocab = llama_model_get_vocab(model);
    auto params = llama_sampler_chain_default_params();
    llama_sampler * chain = llama_sampler_chain_init(params);

    if (!strict_schema.empty()) {
        // The whole output must match (e.g. the agent classification).
        const std::string grammar = json_schema_to_grammar(common_json::parse(strict_schema));
        llama_sampler * grammar_sampler = llama_sampler_init_grammar(vocab, grammar.c_str(), "root");
        if (!grammar_sampler) {
            llama_sampler_free(chain);
            set_error("strict grammar failed to parse");
            return nullptr;
        }
        llama_sampler_chain_add(chain, grammar_sampler);
    } else if (!tool_schema.empty()) {
        const std::string grammar = tool_call_grammar(tool_schema);
        // With thinking on, only a call after </think> counts; the reasoning may mention the tag.
        const char * pattern = thinking ? "</think>[\\s\\S]*?(<tool_call>)" : "(<tool_call>)";
        llama_sampler * grammar_sampler = llama_sampler_init_grammar_lazy_patterns(
            vocab, grammar.c_str(), "root", &pattern, 1, nullptr, 0);
        if (!grammar_sampler) {
            llama_sampler_free(chain);
            set_error("tool-call grammar failed to parse");
            return nullptr;
        }
        llama_sampler_chain_add(chain, grammar_sampler);
    }

    if (dry_multiplier > 0.0f) {
        static const char * breakers[] = {"\n", ":", "\"", "*"};
        llama_sampler_chain_add(chain, llama_sampler_init_dry(vocab, dry_multiplier, 1.75f, 2, -1, breakers, 4));
    }
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(top_k));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(top_p, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_min_p(min_p, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return chain;
}

void forget_cache(Engine * engine) {
    llama_memory_clear(llama_get_memory(engine->ctx), true);
    engine->cached.clear();
}

// Keeps the KV entries shared with the new prompt and drops the rest. Returns how many
// prompt tokens are already evaluated. At least one token is always left to decode so
// the sampler gets fresh logits.
size_t reuse_prefix(Engine * engine, const std::vector<llama_token> & tokens) {
    size_t n = 0;
    const size_t limit = std::min(engine->cached.size(), tokens.size());
    while (n < limit && engine->cached[n] == tokens[n]) n++;
    if (n == tokens.size() && n > 0) n--;
    if (n == 0) {
        forget_cache(engine);
        return 0;
    }
    // Recurrent/hybrid models (e.g. Qwen3.5) cannot drop a tail of their state; start over then.
    if (!llama_memory_seq_rm(llama_get_memory(engine->ctx), 0, static_cast<llama_pos>(n), -1)) {
        forget_cache(engine);
        return 0;
    }
    engine->cached.resize(n);
    return n;
}

bool decode_prompt(Engine * engine, const std::vector<llama_token> & tokens, size_t from) {
    const int n_batch = static_cast<int>(llama_n_batch(engine->ctx));
    for (size_t i = from; i < tokens.size(); i += n_batch) {
        const int n = static_cast<int>(std::min<size_t>(n_batch, tokens.size() - i));
        const int rc = llama_decode(engine->ctx, llama_batch_get_one(const_cast<llama_token *>(tokens.data()) + i, n));
        if (rc != 0) {
            // A half-evaluated batch leaves the cache in an unknown state.
            forget_cache(engine);
            set_error(rc == 2 ? "cancelled" : "prompt decode failed: " + std::to_string(rc));
            return false;
        }
        engine->cached.insert(engine->cached.end(), tokens.begin() + i, tokens.begin() + i + n);
    }
    return true;
}

}  // namespace


#if defined(_WIN32)
#define ARCE_API __declspec(dllexport)
#else
#define ARCE_API __attribute__((visibility("default")))
#endif

extern "C" {

ARCE_API void arce_backend_init() {
    static std::once_flag once;
    std::call_once(once, [] { llama_backend_init(); });
}

ARCE_API const char * arce_last_error() { return g_last_error.c_str(); }

ARCE_API void * arce_load(const char * path, int n_ctx, int n_threads, int n_batch, int n_gpu_layers, bool kv_q8) {
    if (!path) {
        set_error("model path is missing");
        return nullptr;
    }
    auto engine = std::make_unique<Engine>();
    auto mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    mparams.load_mode = LLAMA_LOAD_MODE_MMAP;
    engine->model = llama_model_load_from_file(path, mparams);
    if (!engine->model) {
        set_error("model load failed");
        return nullptr;
    }
    auto cparams = llama_context_default_params();
    cparams.n_ctx = static_cast<uint32_t>(n_ctx);
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;
    if (n_batch > 0) {
        cparams.n_batch = static_cast<uint32_t>(n_batch);
        cparams.n_ubatch = static_cast<uint32_t>(std::min(n_batch, 512));
    }
    if (kv_q8) {
        cparams.type_k = GGML_TYPE_Q8_0;
        cparams.type_v = GGML_TYPE_Q8_0;
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    }
    engine->ctx = llama_init_from_model(engine->model, cparams);
    if (!engine->ctx) {
        set_error("context creation failed (not enough memory for this context length?)");
        return nullptr;
    }
    llama_set_abort_callback(engine->ctx, abort_requested, engine.get());
    LOGI("loaded model, n_ctx=%u", llama_n_ctx(engine->ctx));
    return engine.release();
}

ARCE_API void arce_free(void * engine) { delete static_cast<Engine *>(engine); }

ARCE_API void arce_cancel(void * engine) {
    if (engine) static_cast<Engine *>(engine)->cancel = true;
}

ARCE_API void * arce_start(void * engine_ptr, const char * prompt, const char * tool_schema,
                            const char * strict_schema, bool thinking, int max_tokens, float temperature,
                            float top_p, int top_k, float min_p, float dry_multiplier) {
    auto * engine = static_cast<Engine *>(engine_ptr);
    if (!engine || !prompt) {
        set_error("engine or prompt is missing");
        return nullptr;
    }
    engine->cancel = false;
    auto session = std::make_unique<Session>();
    session->engine = engine;
    try {
        session->sampler = make_sampler(engine->model, tool_schema ? tool_schema : "", strict_schema ? strict_schema : "",
                                        thinking, temperature, top_p, top_k, min_p, dry_multiplier);
    } catch (const std::exception & e) {
        set_error(std::string("tool schema rejected: ") + e.what());
        return nullptr;
    }
    if (!session->sampler) return nullptr;

    const llama_vocab * vocab = llama_model_get_vocab(engine->model);
    const int n_prompt = -llama_tokenize(vocab, prompt, static_cast<int32_t>(std::strlen(prompt)), nullptr, 0, true, true);
    if (n_prompt <= 0) {
        set_error("tokenize failed");
        return nullptr;
    }
    std::vector<llama_token> tokens(n_prompt);
    if (llama_tokenize(vocab, prompt, static_cast<int32_t>(std::strlen(prompt)), tokens.data(), n_prompt, true, true) < 0) {
        set_error("tokenize failed");
        return nullptr;
    }
    const int n_ctx = static_cast<int>(llama_n_ctx(engine->ctx));
    if (n_prompt >= n_ctx) {
        set_error("prompt (" + std::to_string(n_prompt) + " tokens) does not fit the context (" + std::to_string(n_ctx) + ")");
        return nullptr;
    }
    session->max_tokens = std::min<int>(max_tokens, n_ctx - n_prompt);
    const size_t reused = reuse_prefix(engine, tokens);
    LOGI("prompt %d tokens, %zu reused from the KV cache", n_prompt, reused);
    if (!decode_prompt(engine, tokens, reused)) return nullptr;
    return session.release();
}

// Returns a UTF-8 piece (possibly an empty string while a character is incomplete), or null
// after completion. The returned pointer belongs to [session].
ARCE_API const char * arce_next(void * session_ptr) {
    auto * s = static_cast<Session *>(session_ptr);
    if (!s || s->finish != RUNNING) return nullptr;
    Engine * engine = s->engine;
    if (engine->cancel) {
        s->finish = CANCELLED;
        return nullptr;
    }
    if (s->generated >= s->max_tokens) {
        s->finish = LENGTH;
        return nullptr;
    }
    const llama_vocab * vocab = llama_model_get_vocab(engine->model);
    llama_token token = llama_sampler_sample(s->sampler, engine->ctx, -1);
    if (llama_vocab_is_eog(vocab, token)) {
        s->finish = EOG;
        return nullptr;
    }
    char buf[256];
    const int n = llama_token_to_piece(vocab, token, buf, sizeof(buf), 0, true);
    if (n < 0) {
        set_error("token_to_piece failed");
        s->finish = ERROR;
        return nullptr;
    }
    s->utf8_pending.append(buf, static_cast<size_t>(n));
    s->generated++;
    const int rc = llama_decode(engine->ctx, llama_batch_get_one(&token, 1));
    if (rc == 0) {
        engine->cached.push_back(token);
    } else if (rc == 2) {
        forget_cache(engine);
        s->finish = CANCELLED;
    } else {
        forget_cache(engine);
        set_error("decode failed: " + std::to_string(rc));
        s->finish = ERROR;
    }
    const size_t ready = s->finish == RUNNING ? complete_utf8_prefix(s->utf8_pending) : s->utf8_pending.size();
    s->output = s->utf8_pending.substr(0, ready);
    s->utf8_pending.erase(0, ready);
    return s->output.c_str();
}

ARCE_API int arce_finish_reason(void * session) {
    return session ? static_cast<Session *>(session)->finish : ERROR;
}

ARCE_API void arce_end(void * session) { delete static_cast<Session *>(session); }

}  // extern "C"
