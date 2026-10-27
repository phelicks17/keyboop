// Узкий C-интерфейс к llama.cpp для подсказок продолжения (docs/inline-prediction.md).
//
// Наружу из libkeyboop_llm.dylib видны ТОЛЬКО эти функции (exports.txt). Все ggml_* и llama_*
// скрыты внутри библиотеки, поэтому её ggml не встречается с ggml из whisper.cpp, который
// статически влинкован в сам Keyboop. Swift берёт функции через dlsym, llama.h не импортирует.
//
// Хэндл не потокобезопасен: все вызовы с одной последовательной очереди.
#ifndef KB_LLM_H
#define KB_LLM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kb_llm kb_llm;

// Библиотека собирается с -fvisibility=hidden (прячет весь llama.cpp и ggml), поэтому свои
// функции открываем явно. Список экспорта (exports.txt) дополнительно сужает видимое до них.
#define KB_LLM_API __attribute__((visibility("default")))

// Версия интерфейса. Swift сверяет её и отказывается работать с чужой библиотекой.
KB_LLM_API int kb_llm_abi_version(void);

// NULL при ошибке. n_gpu_layers: -1 = всё в Metal, 0 = только CPU.
KB_LLM_API kb_llm *kb_llm_open(const char *model_path, int n_ctx, int n_gpu_layers, int n_threads);

// Продолжение prompt жадной выборкой, не больше max_tokens токенов. Останавливается на конце
// генерации, на служебном токене и на переводе строки (сам перевод в ответ не входит).
// cancel проверяется перед каждым токеном: ненулевое значение = вернуть то, что есть.
// В out пишется UTF-8 без незавершённой последней последовательности и с нулём в конце.
// Возврат: число байт в out (>= 0) или отрицательный код ошибки.
KB_LLM_API int kb_llm_complete(kb_llm *h, const char *prompt, int max_tokens,
                    const volatile int *cancel, char *out, int out_cap);

KB_LLM_API void kb_llm_close(kb_llm *h);

#ifdef __cplusplus
}
#endif

#endif
