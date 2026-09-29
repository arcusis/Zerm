#ifndef BLUE_ORT_BRIDGE_H
#define BLUE_ORT_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

typedef struct BlueORTContext BlueORTContext;
typedef struct {
    const char *name;
    const void *data;
    int element_type;
    int rank;
    int64_t dimensions[8];
} BlueORTInput;
typedef struct {
    void *data;
    int element_type;
    int rank;
    int64_t dimensions[8];
    size_t element_count;
} BlueORTOutput;

BlueORTContext *blue_ort_create(const char *const *model_paths, int model_count, char *error, size_t error_size);
int blue_ort_run(BlueORTContext *context, int model_index, const BlueORTInput *inputs,
                 int input_count, const char *const *output_names, int output_count,
                 BlueORTOutput *outputs,
                 char *error, size_t error_size);
void blue_ort_cancel(BlueORTContext *context);
void blue_ort_clear_cancel(BlueORTContext *context);
char *blue_ort_metadata(BlueORTContext *context, int model_index, const char *key);
void blue_ort_free_string(char *value);
uint64_t blue_current_resident_memory_bytes(void);
char *blue_espeak_phonemize(const char *text, const char *voice, const char *data_path);
void blue_ort_free_output(BlueORTOutput *output);
void blue_ort_destroy(BlueORTContext *context);

#endif
