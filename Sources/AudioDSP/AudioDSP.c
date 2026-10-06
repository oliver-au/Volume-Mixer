#define __STDC_WANT_LIB_EXT1__ 1
#include "AudioDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <strings.h>

_Static_assert(__atomic_always_lock_free(sizeof(float), 0), "Float controls must be lock-free");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0), "Audio telemetry must be lock-free");

struct VMDSPState {
    _Atomic float target;
    _Atomic float peak;
    _Atomic float outputPeak;
    _Atomic uint64_t callbacks;
    _Atomic uint32_t fault;
    float current;
    float step;
    uint32_t offset, inputChannels, outputChannels;
};

static float bounded(float value) {
    return isfinite(value) ? fminf(1.f, fmaxf(0.f, value)) : 1.f;
}

VMDSPState *VMCreateDSP(float gain, double rate, uint32_t offset, uint32_t inCh, uint32_t outCh) {
    if (!isfinite(rate) || rate < 8000 || rate > 384000 ||
        inCh < 1 || inCh > 2 || outCh < 1 || outCh > 2 ||
        (uint64_t)offset + inCh > UINT32_MAX) return NULL;
    VMDSPState *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    atomic_init(&s->target, bounded(gain)); atomic_init(&s->peak, 0); atomic_init(&s->outputPeak, 0);
    atomic_init(&s->callbacks, 0); atomic_init(&s->fault, 0);
    // A full-scale change takes 8 ms; smaller changes remain smooth.
    s->current = bounded(gain); s->step = (float)(1.0 / (rate * .008));
    s->offset = offset; s->inputChannels = inCh; s->outputChannels = outCh;
    return s;
}
void VMDestroyDSP(VMDSPState *s) { free(s); }
void VMSetGain(VMDSPState *s, float gain) { atomic_store_explicit(&s->target, bounded(gain), memory_order_relaxed); }
float VMGetPeak(VMDSPState *s) { return atomic_exchange_explicit(&s->peak, 0, memory_order_relaxed); }
float VMGetOutputPeak(VMDSPState *s) { return atomic_exchange_explicit(&s->outputPeak, 0, memory_order_relaxed); }
uint64_t VMGetCallbackCount(VMDSPState *s) { return atomic_load_explicit(&s->callbacks, memory_order_relaxed); }
uint32_t VMGetFault(VMDSPState *s) { return atomic_load_explicit(&s->fault, memory_order_relaxed); }

static bool channel(const AudioBufferList *list, uint32_t index, float **data, uint32_t *stride, uint32_t *frames) {
    if (!list) return false;
    for (uint32_t i = 0; i < list->mNumberBuffers; ++i) {
        const AudioBuffer *b = &list->mBuffers[i];
        if (index < b->mNumberChannels) {
            if (!b->mData || !b->mNumberChannels) return false;
            *data = ((float *)b->mData) + index;
            *stride = b->mNumberChannels;
            *frames = b->mDataByteSize / (sizeof(float) * b->mNumberChannels);
            return true;
        }
        index -= b->mNumberChannels;
    }
    return false;
}

static uint64_t channels(const AudioBufferList *list) {
    uint64_t count = 0;
    if (list) for (uint32_t b = 0; b < list->mNumberBuffers; ++b) count += list->mBuffers[b].mNumberChannels;
    return count;
}

OSStatus VMRender(VMDSPState *s, const AudioBufferList *input, AudioBufferList *output) {
    if (!s || !output) return noErr;
    // Always initialize every output buffer, including disabled/unexpected streams.
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    // A timing/layout fault remains silent until the control queue tears down the graph.
    if (atomic_load_explicit(&s->fault, memory_order_relaxed)) return noErr;
    if (s->inputChannels < 1 || s->inputChannels > 2 || s->outputChannels < 1 || s->outputChannels > 2 ||
        channels(output) != s->outputChannels ||
        (input && input->mNumberBuffers && channels(input) < (uint64_t)s->offset + s->inputChannels)) {
        atomic_store_explicit(&s->fault, 1, memory_order_relaxed);
        return noErr;
    }
    float *in[2] = {0}, *out[2] = {0};
    uint32_t is[2] = {0}, os[2] = {0}, inputFrames = UINT32_MAX, outputFrames = UINT32_MAX, f = 0;
    for (uint32_t c = 0; c < s->inputChannels; c++) {
        if (!channel(input, s->offset + c, &in[c], &is[c], &f)) {
            atomic_store_explicit(&s->peak, 0, memory_order_relaxed);
            atomic_store_explicit(&s->outputPeak, 0, memory_order_relaxed);
            return noErr; // Silent/idle tap.
        }
        if (f < inputFrames) inputFrames = f;
    }
    for (uint32_t c = 0; c < s->outputChannels; c++) {
        if (!channel(output, c, &out[c], &os[c], &f)) { atomic_store(&s->fault, 1); return noErr; }
        if (f < outputFrames) outputFrames = f;
    }
    if (!inputFrames || !outputFrames) {
        atomic_store_explicit(&s->peak, 0, memory_order_relaxed);
        atomic_store_explicit(&s->outputPeak, 0, memory_order_relaxed);
        return noErr;
    }
    // The direct path is only valid on one clock. Never truncate unmatched
    // buffers; a changed stream must be rebuilt through buffered playback.
    if (inputFrames != outputFrames) { atomic_store(&s->fault, 2); return noErr; }
    float target = atomic_load_explicit(&s->target, memory_order_relaxed), peak = 0, outputPeak = 0;
    uint32_t count = inputFrames < outputFrames ? inputFrames : outputFrames;
    for (uint32_t i = 0; i < count; i++) {
        float delta = target - s->current;
        s->current += fmaxf(-s->step, fminf(s->step, delta));
        float left = in[0][i * is[0]], right = s->inputChannels == 2 ? in[1][i * is[1]] : left;
        if (!isfinite(left)) left = 0;
        if (!isfinite(right)) right = 0;
        peak = fmaxf(peak, fmaxf(fabsf(left), fabsf(right)));
        if (s->outputChannels == 1) {
            float sample = (left * .5f + right * .5f) * s->current;
            out[0][i * os[0]] = sample; outputPeak = fmaxf(outputPeak, fabsf(sample));
        } else {
            out[0][i * os[0]] = left * s->current; out[1][i * os[1]] = right * s->current;
            outputPeak = fmaxf(outputPeak, fmaxf(fabsf(left), fabsf(right)) * s->current);
        }
    }
    atomic_store_explicit(&s->peak, peak, memory_order_relaxed);
    atomic_store_explicit(&s->outputPeak, outputPeak, memory_order_relaxed);
    return noErr;
}

OSStatus VMIOProc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                 const AudioTimeStamp *inputTime, AudioBufferList *output,
                 const AudioTimeStamp *outputTime, void *context) {
    return VMRender(context, input, output);
}

OSStatus VMCreateIOProc(AudioObjectID device, VMDSPState *state, AudioDeviceIOProcID *proc) {
    return AudioDeviceCreateIOProcID(device, VMIOProc, state, proc);
}

OSStatus VMSetInputUsage(AudioObjectID device, AudioDeviceIOProcID proc, uint32_t count, uint32_t first) {
    if (!count || first >= count) return kAudioHardwareIllegalOperationError;
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = proc; usage->mNumberStreams = count;
    for (uint32_t i = first; i < count; ++i) usage->mStreamIsOn[i] = 1;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    OSStatus result = AudioObjectSetPropertyData(device, &a, 0, NULL, (UInt32)size, usage);
    free(usage);
    return result;
}

enum { BridgeCapacity = 65536, BridgeMaxSlice = 16384 };
struct VMBridge {
    float *ring, *scratch, *fadeTail;
    VMDSPState *dsp;
    uint32_t inputChannels, outputChannels;
    uint32_t fadeLength, fadePosition, extraLatencyFrames;
    _Atomic uint64_t written, read, deliveredFrames, underruns, droppedFrames;
    _Atomic uint32_t fault, targetFrames;
    bool primed; // Only the playback callback touches this field.
};
VMBridge *VMCreateBridge(float gain, double rate, uint32_t inputChannels, uint32_t outputChannels) {
    VMDSPState *dsp = VMCreateDSP(gain, rate, 0, inputChannels, outputChannels);
    if (!dsp) return NULL;
    VMBridge *s = calloc(1, sizeof(*s));
    if (!s) { VMDestroyDSP(dsp); return NULL; }
    s->dsp = dsp; s->inputChannels = inputChannels; s->outputChannels = outputChannels;
    s->ring = calloc(BridgeCapacity * inputChannels, sizeof(float));
    s->scratch = calloc(BridgeMaxSlice * inputChannels, sizeof(float));
    s->fadeLength = (uint32_t)ceil(rate * .005); s->fadePosition = s->fadeLength;
    s->extraLatencyFrames = (uint32_t)ceil(rate * .25);
    s->fadeTail = calloc(s->fadeLength * inputChannels, sizeof(float));
    if (!s->ring || !s->scratch || !s->fadeTail) { VMDestroyBridge(s); return NULL; }
    atomic_init(&s->written, 0); atomic_init(&s->read, 0);
    atomic_init(&s->deliveredFrames, 0);
    atomic_init(&s->underruns, 0); atomic_init(&s->fault, 0); atomic_init(&s->targetFrames, 2048);
    atomic_init(&s->droppedFrames, 0);
    return s;
}
void VMDestroyBridge(VMBridge *s) {
    if (!s) return;
    VMDestroyDSP(s->dsp); free(s->ring); free(s->scratch); free(s->fadeTail); free(s);
}
void VMBridgeSetGain(VMBridge *s, float gain) { VMSetGain(s->dsp, gain); }
uint32_t VMBridgeFault(VMBridge *s) {
    uint32_t fault = atomic_load_explicit(&s->fault, memory_order_relaxed);
    return fault ? fault : VMGetFault(s->dsp);
}
uint32_t VMBridgeQueuedFrames(VMBridge *s) {
    uint64_t read = atomic_load_explicit(&s->read, memory_order_acquire);
    uint64_t written = atomic_load_explicit(&s->written, memory_order_acquire);
    return written >= read && written - read <= BridgeCapacity ? (uint32_t)(written - read) : 0;
}
uint32_t VMBridgeTargetFrames(VMBridge *s) { return atomic_load_explicit(&s->targetFrames, memory_order_relaxed); }
uint64_t VMBridgeDeliveredFrames(VMBridge *s) { return atomic_load_explicit(&s->deliveredFrames, memory_order_relaxed); }
uint64_t VMBridgeUnderruns(VMBridge *s) { return atomic_load_explicit(&s->underruns, memory_order_relaxed); }
uint64_t VMBridgeDroppedFrames(VMBridge *s) { return atomic_load_explicit(&s->droppedFrames, memory_order_relaxed); }
float VMBridgePeak(VMBridge *s) { return VMGetPeak(s->dsp); }
float VMBridgeOutputPeak(VMBridge *s) { return VMGetOutputPeak(s->dsp); }

void VMBridgeCapture(VMBridge *s, const AudioBufferList *input) {
    if (VMBridgeFault(s) || !input || !input->mNumberBuffers) return;
    if (channels(input) != s->inputChannels) { atomic_store(&s->fault, 1); return; }
    float *data[2] = {0}; uint32_t stride[2] = {0}, frames = UINT32_MAX, f = 0;
    for (uint32_t c = 0; c < s->inputChannels; ++c) {
        if (!channel(input, c, &data[c], &stride[c], &f)) return;
        if (f < frames) frames = f;
    }
    uint64_t written = atomic_load_explicit(&s->written, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&s->read, memory_order_acquire);
    if (frames > BridgeCapacity || written + frames - read > BridgeCapacity) { atomic_store(&s->fault, 3); return; }
    for (uint32_t i = 0; i < frames; ++i) {
        uint32_t slot = (uint32_t)((written + i) & (BridgeCapacity - 1)) * s->inputChannels;
        for (uint32_t c = 0; c < s->inputChannels; ++c) {
            float sample = data[c][i * stride[c]];
            s->ring[slot + c] = isfinite(sample) ? sample : 0;
        }
    }
    // Publish only complete frames; the consumer never reads an unfinished sample.
    atomic_store_explicit(&s->written, written + frames, memory_order_release);
}
OSStatus VMBridgeRender(VMBridge *s, uint32_t frames, AudioBufferList *output) {
    if (!s || !output) return noErr;
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    if (VMBridgeFault(s) || !frames) return noErr;
    if (frames > BridgeMaxSlice || output->mNumberBuffers > 2 || channels(output) != s->outputChannels) { atomic_store(&s->fault, 1); return noErr; }
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &output->mBuffers[b];
        if (!buffer->mData || (uint64_t)buffer->mDataByteSize < (uint64_t)frames * buffer->mNumberChannels * sizeof(float)) {
            atomic_store(&s->fault, 1); return noErr;
        }
    }
    uint32_t target = frames * 2 > 2048 ? frames * 2 : 2048;
    if (target > BridgeCapacity / 2) target = BridgeCapacity / 2;
    atomic_store_explicit(&s->targetFrames, target, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&s->read, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&s->written, memory_order_acquire);
    uint64_t available = written - read;
    // Ordinary packet-size variation and slow drift keep the continuous path.
    // A large backlog (for example a 500 ms output stall) returns to the target
    // promptly, crossfading five milliseconds of old/new audio on the consumer.
    uint32_t limit = target * 4;
    if (limit < target + s->extraLatencyFrames) limit = target + s->extraLatencyFrames;
    if (limit > BridgeCapacity - BridgeMaxSlice) limit = BridgeCapacity - BridgeMaxSlice;
    if (available > limit) {
        for (uint32_t i = 0; i < s->fadeLength; ++i) {
            uint32_t slot = (uint32_t)((read + i) & (BridgeCapacity - 1)) * s->inputChannels;
            for (uint32_t c = 0; c < s->inputChannels; ++c) {
                float sample = s->ring[slot + c];
                // Preserve continuity even if another stall interrupts a fade.
                uint32_t previous = s->fadePosition + i;
                if (previous < s->fadeLength) {
                    float mix = (float)(previous + 1) / s->fadeLength;
                    sample = s->fadeTail[previous * s->inputChannels + c] * (1.f - mix) + sample * mix;
                }
                s->fadeTail[i * s->inputChannels + c] = sample;
            }
        }
        uint64_t next = written - target;
        atomic_fetch_add_explicit(&s->droppedFrames, next - read, memory_order_relaxed);
        read = next; available = target; s->fadePosition = 0;
        // Publish the new read position only AFTER copying all old/new samples.
        // Until then the producer cannot overwrite data needed for this render.
    }
    if (!s->primed) {
        if (available < target) return noErr;
        s->primed = true;
    }
    if (available < frames) {
        // A stopped source is allowed to become idle. Re-prime when it resumes;
        // repeated starvation of an active source is detected by the control queue.
        atomic_fetch_add_explicit(&s->underruns, 1, memory_order_relaxed);
        atomic_store_explicit(&s->read, written, memory_order_release);
        s->primed = false; return noErr;
    }
    for (uint32_t i = 0; i < frames; ++i) {
        uint32_t slot = (uint32_t)((read + i) & (BridgeCapacity - 1)) * s->inputChannels;
        for (uint32_t c = 0; c < s->inputChannels; ++c) {
            float sample = s->ring[slot + c];
            if (s->fadePosition < s->fadeLength) {
                float mix = (float)(s->fadePosition + 1) / s->fadeLength;
                sample = s->fadeTail[s->fadePosition * s->inputChannels + c] * (1.f - mix) + sample * mix;
            }
            s->scratch[i * s->inputChannels + c] = sample;
        }
        if (s->fadePosition < s->fadeLength) s->fadePosition++;
    }
    atomic_store_explicit(&s->read, read + frames, memory_order_release);
    atomic_fetch_add_explicit(&s->deliveredFrames, frames, memory_order_relaxed);
    AudioBufferList input = { .mNumberBuffers = 1, .mBuffers = {{s->inputChannels, frames * s->inputChannels * sizeof(float), s->scratch}} };
    // Some clients expose capacity in mDataByteSize. Process exactly the requested
    // frame count without assuming the input and output allocation sizes match.
    struct { UInt32 count; AudioBuffer buffers[2]; } slice = { .count = output->mNumberBuffers };
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b) {
        slice.buffers[b] = output->mBuffers[b];
        slice.buffers[b].mDataByteSize = frames * slice.buffers[b].mNumberChannels * sizeof(float);
    }
    return VMRender(s->dsp, &input, (AudioBufferList *)&slice);
}
static OSStatus bridgeCaptureIO(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                                const AudioTimeStamp *inputTime, AudioBufferList *output,
                                const AudioTimeStamp *outputTime, void *context) {
    if (output) for (uint32_t b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    VMBridgeCapture(context, input); return noErr;
}
OSStatus VMCreateCaptureIOProc(AudioObjectID device, VMBridge *s, AudioDeviceIOProcID *proc) {
    return AudioDeviceCreateIOProcID(device, bridgeCaptureIO, s, proc);
}

uint64_t VMProcessStartTime(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}

bool VMExtractWineMetadata(const void *bytes, size_t size, VMProcessInfo *info) {
    if (!info) return false;
    info->wineExecutable[0] = 0; info->wineBottle[0] = 0;
    if (!bytes || size <= sizeof(int)) return false;
    int argc = 0; memcpy(&argc, bytes, sizeof(int));
    if (argc < 1 || argc > 65536) return false;
    const char *p = (const char *)bytes + sizeof(int), *end = (const char *)bytes + size;
    size_t len = strnlen(p, end-p);
    if (p+len >= end) return false;
    p += len;
    while (p < end && !*p) p++;
    bool ambiguous = false;
    for (int n = 0; n < argc; n++) {
        if (p >= end) goto invalid;
        len = strnlen(p, end-p); if (p+len >= end) goto invalid;
        if (len > 4 && !strcasecmp(p+len-4, ".exe") && !strcasestr(p, "winewrapper.exe")) {
            if (len >= sizeof(info->wineExecutable)) goto invalid;
            if (info->wineExecutable[0] && strcasecmp(info->wineExecutable, p)) ambiguous = true;
            else strlcpy(info->wineExecutable, p, sizeof(info->wineExecutable));
        }
        p += len+1;
    }
    while (p < end) {
        len = strnlen(p, end-p); if (p+len >= end) goto invalid;
        if (len >= 11 && !strncmp(p, "WINEPREFIX=", 11)) {
            if (len - 11 >= sizeof(info->wineBottle)) goto invalid;
            strlcpy(info->wineBottle, p+11, sizeof(info->wineBottle));
        } else if (len >= 10 && !info->wineBottle[0] && !strncmp(p, "CX_BOTTLE=", 10)) {
            if (len - 10 >= sizeof(info->wineBottle)) goto invalid;
            strlcpy(info->wineBottle, p+10, sizeof(info->wineBottle));
        }
        p += len+1;
    }
    if (ambiguous) info->wineExecutable[0] = 0;
    return true;
invalid:
    info->wineExecutable[0] = 0; info->wineBottle[0] = 0;
    return false;
}

bool VMReadProcessInfo(pid_t pid, VMProcessInfo *info) {
    if (!info) return false;
    memset(info, 0, sizeof(*info));
    struct proc_bsdinfo bsd = {0};
    int result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
    if (result != sizeof(bsd)) return false;
    info->parent = bsd.pbi_ppid;
    info->startTime = bsd.pbi_start_tvsec * 1000000ULL + bsd.pbi_start_tvusec;
    proc_pidpath(pid, info->executable, sizeof(info->executable));
    info->executable[sizeof(info->executable) - 1] = 0;
    size_t nameLength = strnlen(bsd.pbi_name, sizeof(bsd.pbi_name));
    if (nameLength >= sizeof(info->name)) nameLength = sizeof(info->name) - 1;
    memcpy(info->name, bsd.pbi_name, nameLength);
    if (!strcasestr(info->executable, "wine") && !strcasestr(info->executable, "crossover") &&
        !strcasestr(info->executable, ".exe")) return true;
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    const size_t capacity = 256 * 1024;
    size_t size = capacity;
    char *args = calloc(1, capacity);
    if (!args) return true;
    if (sysctl(mib, 3, args, &size, NULL, 0) == 0 && size <= capacity) VMExtractWineMetadata(args, size, info);
    // The OS returns the whole argument/environment block. Discard unrelated
    // values immediately; only the two allowlisted Wine identity fields survive.
    (void)memset_s(args, capacity, 0, capacity);
    free(args);
    return true;
}
