// Реализация kb_llm.h поверх llama.cpp (тег b11600). Пояснения к границам — в kb_llm.h.
#include "kb_llm.h"
#include "llama.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KB_LLM_ABI 1

// Ошибки kb_llm_complete.
#define KB_ERR_ARGS     (-1)
#define KB_ERR_TOKENIZE (-2)
#define KB_ERR_DECODE   (-3)
#define KB_ERR_TOO_LONG (-4)

struct kb_llm {
    struct llama_model *model;
    struct llama_context *ctx;
    const struct llama_vocab *vocab;
    struct llama_sampler *sampler;
    int n_ctx;
    // Токены, которые сейчас лежат в KV-кэше (промпт + сгенерированное прошлым вызовом).
    // Подсказки идут на каждой паузе, и промпт почти всегда отличается от прошлого только
    // хвостом: общий префикс не пересчитываем.
    llama_token *cached;
    int n_cached;
};

// llama.cpp по умолчанию пишет в stderr построчно о каждой загрузке. Оставляем только ошибки.
static void kb_log(enum ggml_log_level level, const char *text, void *user) {
    (void)user;
    if (level == GGML_LOG_LEVEL_ERROR) { fputs(text, stderr); }
}

int kb_llm_abi_version(void) { return KB_LLM_ABI; }

kb_llm *kb_llm_open(const char *model_path, int n_ctx, int n_gpu_layers, int n_threads) {
    if (!model_path || n_ctx < 256) { return NULL; }
    llama_log_set(kb_log, NULL);
    llama_backend_init();

    struct llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = n_gpu_layers;
    struct llama_model *model = llama_model_load_from_file(model_path, mp);
    if (!model) { return NULL; }

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)n_ctx;
    cp.n_batch = (uint32_t)n_ctx;
    if (n_threads > 0) { cp.n_threads = n_threads; cp.n_threads_batch = n_threads; }
    struct llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) { llama_model_free(model); return NULL; }

    kb_llm *h = calloc(1, sizeof(*h));
    llama_token *cached = calloc((size_t)n_ctx, sizeof(llama_token));
    if (!h || !cached) {
        free(h); free(cached);
        llama_free(ctx); llama_model_free(model);
        return NULL;
    }
    h->model = model;
    h->ctx = ctx;
    h->vocab = llama_model_get_vocab(model);
    h->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(h->sampler, llama_sampler_init_greedy());
    h->n_ctx = n_ctx;
    h->cached = cached;
    return h;
}

// Длина хвоста, который является началом незавершённой UTF-8 последовательности.
static int kb_incomplete_utf8_tail(const char *s, int n) {
    for (int back = 1; back <= 3 && back <= n; back++) {
        unsigned char c = (unsigned char)s[n - back];
        if ((c & 0xC0) == 0x80) { continue; }            // байт продолжения, смотрим левее
        int need = (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 1;
        return need > back ? back : 0;
    }
    return 0;
}

// Положить токены в контекст (decode) по одному батчу и запомнить их в cached.
static int kb_feed(kb_llm *h, llama_token *toks, int n) {
    if (n <= 0) { return 0; }
    if (h->n_cached + n > h->n_ctx) { return KB_ERR_TOO_LONG; }
    if (llama_decode(h->ctx, llama_batch_get_one(toks, n)) != 0) { return KB_ERR_DECODE; }
    memcpy(h->cached + h->n_cached, toks, (size_t)n * sizeof(llama_token));
    h->n_cached += n;
    return 0;
}

int kb_llm_complete(kb_llm *h, const char *prompt, int max_tokens,
                    const volatile int *cancel, char *out, int out_cap) {
    if (!h || !prompt || !out || out_cap < 1 || max_tokens < 1) { return KB_ERR_ARGS; }
    out[0] = 0;

    int len = (int)strlen(prompt);
    llama_token *toks = malloc((size_t)h->n_ctx * sizeof(llama_token));
    if (!toks) { return KB_ERR_ARGS; }
    // parse_special: промпт содержит разметку ходов Gemma (<|turn> и т.п.), это токены, а не текст.
    int n = llama_tokenize(h->vocab, prompt, len, toks, h->n_ctx, true, true);
    if (n < 0 || n + max_tokens > h->n_ctx) { free(toks); return n < 0 ? KB_ERR_TOKENIZE : KB_ERR_TOO_LONG; }

    // Общий префикс с тем, что уже в KV-кэше. Хотя бы последний токен промпта прогоняем заново,
    // иначе не будет логитов для первого шага генерации.
    int keep = 0;
    while (keep < h->n_cached && keep < n - 1 && h->cached[keep] == toks[keep]) { keep++; }
    llama_memory_t mem = llama_get_memory(h->ctx);
    if (!llama_memory_seq_rm(mem, 0, keep, -1)) {
        // Кэш со скользящим окном (у Gemma он есть) не всегда умеет отрезать хвост. Тогда честно
        // начинаем с нуля: медленнее, но правильно.
        llama_memory_clear(mem, true);
        keep = 0;
    }
    h->n_cached = keep;

    int rc = kb_feed(h, toks + keep, n - keep);
    free(toks);
    if (rc != 0) { llama_memory_clear(mem, true); h->n_cached = 0; return rc; }

    int used = 0;
    for (int i = 0; i < max_tokens; i++) {
        if (cancel && *cancel) { break; }
        llama_token t = llama_sampler_sample(h->sampler, h->ctx, -1);
        if (llama_vocab_is_eog(h->vocab, t) || llama_vocab_is_control(h->vocab, t)) { break; }
        char piece[256];
        int pn = llama_token_to_piece(h->vocab, t, piece, (int)sizeof(piece), 0, false);
        if (pn < 0) { break; }
        char *nl = memchr(piece, '\n', (size_t)pn);
        if (nl) { pn = (int)(nl - piece); }
        if (used + pn >= out_cap) { break; }
        memcpy(out + used, piece, (size_t)pn);
        used += pn;
        if (nl) { break; }
        if (i + 1 < max_tokens && kb_feed(h, &t, 1) != 0) { break; }
    }
    used -= kb_incomplete_utf8_tail(out, used);
    out[used] = 0;
    return used;
}

void kb_llm_close(kb_llm *h) {
    if (!h) { return; }
    llama_sampler_free(h->sampler);
    llama_free(h->ctx);
    llama_model_free(h->model);
    free(h->cached);
    free(h);
}
