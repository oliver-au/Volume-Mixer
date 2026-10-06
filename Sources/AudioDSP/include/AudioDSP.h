#ifndef VOLUME_MIXER_DSP_H
#define VOLUME_MIXER_DSP_H
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct VMDSPState VMDSPState;
VMDSPState *VMCreateDSP(float gain, double sampleRate, uint32_t inputChannelOffset,
                       uint32_t inputChannels, uint32_t outputChannels);
void VMDestroyDSP(VMDSPState *state);
void VMSetGain(VMDSPState *state, float gain);
float VMGetPeak(VMDSPState *state);
float VMGetOutputPeak(VMDSPState *state);
uint64_t VMGetCallbackCount(VMDSPState *state);
uint32_t VMGetFault(VMDSPState *state);
OSStatus VMRender(VMDSPState *state, const AudioBufferList *input, AudioBufferList *output);
OSStatus VMIOProc(AudioObjectID device, const AudioTimeStamp *now,
                  const AudioBufferList *input, const AudioTimeStamp *inputTime,
                  AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
OSStatus VMSetInputUsage(AudioObjectID device, AudioDeviceIOProcID proc,
                         uint32_t streamCount, uint32_t firstTapStream);
OSStatus VMCreateIOProc(AudioObjectID device, VMDSPState *state, AudioDeviceIOProcID *proc);

// Separate capture/playback callbacks communicate through a bounded SPSC queue.
typedef struct VMBridge VMBridge;
VMBridge *VMCreateBridge(float gain, double rate, uint32_t inputChannels, uint32_t outputChannels);
void VMDestroyBridge(VMBridge *bridge);
void VMBridgeSetGain(VMBridge *bridge, float gain);
void VMBridgeCapture(VMBridge *bridge, const AudioBufferList *input);
OSStatus VMBridgeRender(VMBridge *bridge, uint32_t frames, AudioBufferList *output);
OSStatus VMCreateCaptureIOProc(AudioObjectID device, VMBridge *bridge, AudioDeviceIOProcID *proc);
uint64_t VMBridgeDeliveredFrames(VMBridge *bridge);
uint32_t VMBridgeFault(VMBridge *bridge);
uint32_t VMBridgeQueuedFrames(VMBridge *bridge);
uint32_t VMBridgeTargetFrames(VMBridge *bridge);
uint64_t VMBridgeUnderruns(VMBridge *bridge);
uint64_t VMBridgeDroppedFrames(VMBridge *bridge);
float VMBridgePeak(VMBridge *bridge);
float VMBridgeOutputPeak(VMBridge *bridge);

// Read only this process's public identity plus Wine executable/bottle metadata.
// No command line or environment data is returned except those two fields.
typedef struct {
    pid_t parent;
    uint64_t startTime;
    char executable[4096];
    char name[256];
    char wineExecutable[4096];
    char wineBottle[4096];
} VMProcessInfo;
bool VMReadProcessInfo(pid_t pid, VMProcessInfo *info);
uint64_t VMProcessStartTime(pid_t pid);
// Parse bounded KERN_PROCARGS2-format bytes, exposing only Wine identity fields.
bool VMExtractWineMetadata(const void *bytes, size_t size, VMProcessInfo *info);
#endif
