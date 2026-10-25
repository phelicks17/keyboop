// Bridging header — открывает C API whisper.cpp для Swift.
// Реальная reference: vendor/whisper.cpp/include/whisper.h
#ifndef KEYBOOP_WHISPER_BRIDGING_H
#define KEYBOOP_WHISPER_BRIDGING_H

#include "whisper.h"

// ONNX Runtime для GigaAM (GigaAMCore.swift). Только arm64: x86-срез GigaAM не собирает, и его
// сборке не нужен путь к заголовкам ORT. Сама библиотека грузится через dlopen, не линкуется.
#if defined(__arm64__)
#include "onnxruntime_c_api.h"
#endif

#endif
