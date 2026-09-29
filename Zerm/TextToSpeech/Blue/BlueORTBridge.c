#include "BlueORTBridge.h"
#include <onnxruntime_c_api.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <espeak-ng/speak_lib.h>

struct BlueORTContext {
    const OrtApi *api;
    OrtEnv *env;
    OrtSessionOptions *options;
    OrtMemoryInfo *memory;
    OrtSession **sessions;
    int session_count;
    OrtRunOptions *run_options;
    pthread_mutex_t run_lock;
    int cancelled;
};

static void set_error(char *buffer, size_t size, const char *message) {
    if (!buffer || !size) return;
    snprintf(buffer, size, "%s", message ? message : "ONNX Runtime error");
}

static int check_status(BlueORTContext *context, OrtStatus *status, char *error, size_t error_size) {
    if (!status) return 1;
    set_error(error, error_size, context->api->GetErrorMessage(status));
    context->api->ReleaseStatus(status);
    return 0;
}

BlueORTContext *blue_ort_create(const char *const *paths, int count, char *error, size_t error_size) {
    BlueORTContext *context = calloc(1, sizeof(*context));
    if (!context) { set_error(error, error_size, "Out of memory"); return NULL; }
    context->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    pthread_mutex_init(&context->run_lock, NULL);
    OrtStatus *status = context->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "Zerm.Blue", &context->env);
    if (!check_status(context, status, error, error_size)) goto fail;
    status = context->api->CreateSessionOptions(&context->options);
    if (!check_status(context, status, error, error_size)) goto fail;
    context->api->SetIntraOpNumThreads(context->options, 4);
    context->api->SetInterOpNumThreads(context->options, 1);
    context->api->SetSessionGraphOptimizationLevel(context->options, ORT_ENABLE_ALL);
    status = context->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &context->memory);
    if (!check_status(context, status, error, error_size)) goto fail;
    status = context->api->CreateRunOptions(&context->run_options);
    if (!check_status(context, status, error, error_size)) goto fail;
    context->sessions = calloc((size_t)count, sizeof(OrtSession *));
    context->session_count = count;
    if (!context->sessions) { set_error(error, error_size, "Out of memory"); goto fail; }
    for (int i = 0; i < count; i++) {
        status = context->api->CreateSession(context->env, paths[i], context->options, &context->sessions[i]);
        if (!check_status(context, status, error, error_size)) goto fail;
    }
    return context;
fail:
    blue_ort_destroy(context);
    return NULL;
}

int blue_ort_run(BlueORTContext *context, int index, const BlueORTInput *inputs,
                 int count, const char *const *output_names, int output_count,
                 BlueORTOutput *outputs,
                 char *error, size_t error_size) {
    if (!context || index < 0 || index >= context->session_count) return 0;
    OrtValue **values = calloc((size_t)count, sizeof(OrtValue *));
    const char **names = calloc((size_t)count, sizeof(char *));
    if (!values || !names) { free(values); free(names); set_error(error, error_size, "Out of memory"); return 0; }
    int ok = 0;
    for (int i = 0; i < count; i++) {
        names[i] = inputs[i].name;
        size_t elements = 1;
        for (int d = 0; d < inputs[i].rank; d++) elements *= (size_t)inputs[i].dimensions[d];
        size_t element_size = inputs[i].element_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 ? sizeof(int64_t) : sizeof(float);
        OrtStatus *status = context->api->CreateTensorWithDataAsOrtValue(
            context->memory, (void *)inputs[i].data, elements * element_size, inputs[i].dimensions, (size_t)inputs[i].rank,
            (ONNXTensorElementDataType)inputs[i].element_type, &values[i]);
        if (!check_status(context, status, error, error_size)) goto done;
    }
    OrtValue **output_values = calloc((size_t)output_count, sizeof(OrtValue *));
    if (!output_values) { set_error(error, error_size, "Out of memory"); goto done; }
    OrtStatus *status = context->api->Run(context->sessions[index], context->run_options,
        names, (const OrtValue *const *)values, (size_t)count, output_names, (size_t)output_count, output_values);
    if (!check_status(context, status, error, error_size)) goto done;
    for (int i = 0; i < output_count; i++) {
        OrtTensorTypeAndShapeInfo *info = NULL;
        status = context->api->GetTensorTypeAndShape(output_values[i], &info);
        if (!check_status(context, status, error, error_size)) goto done_outputs;
        size_t rank = 0;
        context->api->GetDimensionsCount(info, &rank);
        if (rank > 8) { context->api->ReleaseTensorTypeAndShapeInfo(info); set_error(error, error_size, "Unexpected ONNX tensor rank"); goto done_outputs; }
        outputs[i].rank = (int)rank;
        context->api->GetDimensions(info, outputs[i].dimensions, rank);
        context->api->GetTensorShapeElementCount(info, &outputs[i].element_count);
        context->api->GetTensorElementType(info, (ONNXTensorElementDataType *)&outputs[i].element_type);
        context->api->ReleaseTensorTypeAndShapeInfo(info);
        void *raw = NULL;
        status = context->api->GetTensorMutableData(output_values[i], &raw);
        if (!check_status(context, status, error, error_size)) goto done_outputs;
        size_t element_size = outputs[i].element_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 ? sizeof(int64_t) : sizeof(float);
        outputs[i].data = malloc(outputs[i].element_count * element_size);
        if (!outputs[i].data) { set_error(error, error_size, "Out of memory"); goto done_outputs; }
        memcpy(outputs[i].data, raw, outputs[i].element_count * element_size);
    }
    ok = 1;
done_outputs:
    for (int i = 0; i < output_count; i++) if (output_values[i]) context->api->ReleaseValue(output_values[i]);
    free(output_values);
done:
    for (int i = 0; i < count; i++) if (values[i]) context->api->ReleaseValue(values[i]);
    free(values);
    free(names);
    return ok;
}

void blue_ort_cancel(BlueORTContext *context) {
    if (!context) return;
    pthread_mutex_lock(&context->run_lock);
    context->cancelled = 1;
    context->api->RunOptionsSetTerminate(context->run_options);
    pthread_mutex_unlock(&context->run_lock);
}

void blue_ort_clear_cancel(BlueORTContext *context) {
    if (!context) return;
    pthread_mutex_lock(&context->run_lock);
    context->cancelled = 0;
    context->api->RunOptionsUnsetTerminate(context->run_options);
    pthread_mutex_unlock(&context->run_lock);
}

char *blue_ort_metadata(BlueORTContext *context, int index, const char *key) {
    if (!context || index < 0 || index >= context->session_count) return NULL;
    OrtModelMetadata *metadata = NULL;
    OrtStatus *status = context->api->SessionGetModelMetadata(context->sessions[index], &metadata);
    if (status) { context->api->ReleaseStatus(status); return NULL; }
    OrtAllocator *allocator = NULL;
    status = context->api->GetAllocatorWithDefaultOptions(&allocator);
    if (status) { context->api->ReleaseStatus(status); context->api->ReleaseModelMetadata(metadata); return NULL; }
    char *value = NULL;
    status = context->api->ModelMetadataLookupCustomMetadataMap(metadata, allocator, key, &value);
    char *copy = (!status && value) ? strdup(value) : NULL;
    if (status) context->api->ReleaseStatus(status);
    if (value) context->api->AllocatorFree(allocator, value);
    context->api->ReleaseModelMetadata(metadata);
    return copy;
}

void blue_ort_free_string(char *value) { free(value); }

uint64_t blue_current_resident_memory_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (uint64_t)info.resident_size;
}

static pthread_mutex_t espeak_lock = PTHREAD_MUTEX_INITIALIZER;
static char *espeak_data_path;

char *blue_espeak_phonemize(const char *text, const char *voice, const char *data_path) {
    if (!text || !voice || !data_path) return NULL;
    pthread_mutex_lock(&espeak_lock);
    if (!espeak_data_path || strcmp(espeak_data_path, data_path) != 0) {
        if (espeak_data_path) {
            espeak_Terminate();
            free(espeak_data_path);
            espeak_data_path = NULL;
        }
        if (espeak_Initialize(AUDIO_OUTPUT_RETRIEVAL, 0, data_path, espeakINITIALIZE_PHONEME_IPA) < 0) {
            pthread_mutex_unlock(&espeak_lock);
            return NULL;
        }
        espeak_data_path = strdup(data_path);
    }
    if (espeak_SetVoiceByName(voice) != EE_OK) {
        pthread_mutex_unlock(&espeak_lock);
        return NULL;
    }
    size_t capacity = strlen(text) * 8 + 64;
    char *result = calloc(capacity, 1);
    if (!result) { pthread_mutex_unlock(&espeak_lock); return NULL; }
    const void *cursor = text;
    size_t used = 0;
    int clauses = 0;
    while (cursor && clauses++ < 1000) {
        const char *phonemes = espeak_TextToPhonemes(&cursor, espeakCHARS_UTF8, espeakPHONEMES_IPA);
        if (!phonemes) break;
        size_t length = strlen(phonemes);
        if (used + length + 2 >= capacity) {
            capacity = (used + length + 2) * 2;
            char *expanded = realloc(result, capacity);
            if (!expanded) { free(result); pthread_mutex_unlock(&espeak_lock); return NULL; }
            result = expanded;
        }
        memcpy(result + used, phonemes, length);
        used += length;
        result[used] = ' ';
        result[++used] = '\0';
    }
    while (used && result[used - 1] == ' ') result[--used] = '\0';
    pthread_mutex_unlock(&espeak_lock);
    return result;
}

void blue_ort_free_output(BlueORTOutput *output) {
    if (!output) return;
    if (output->data) free(output->data);
    memset(output, 0, sizeof(*output));
}

void blue_ort_destroy(BlueORTContext *context) {
    if (!context) return;
    if (context->sessions) {
        for (int i = 0; i < context->session_count; i++) if (context->sessions[i]) context->api->ReleaseSession(context->sessions[i]);
        free(context->sessions);
    }
    if (context->run_options) context->api->ReleaseRunOptions(context->run_options);
    if (context->memory) context->api->ReleaseMemoryInfo(context->memory);
    if (context->options) context->api->ReleaseSessionOptions(context->options);
    if (context->env) context->api->ReleaseEnv(context->env);
    pthread_mutex_destroy(&context->run_lock);
    free(context);
}
