// Portable execution of mechanically adapted production method excerpts.
// AVFoundation objects/weak ownership, CoreVideo counters and locks are labelled doubles.
#include <algorithm>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
using BOOL = bool;
using NSUInteger = size_t;
using dispatch_queue_t = void *;
struct Exception {};
static Exception injected;
struct Delegate { virtual ~Delegate() = default; };
struct Buffer { int retains = 1; };
using CVPixelBufferRef = Buffer *;
static int finalizations;
static void CVPixelBufferRelease(Buffer *buffer) { if (--buffer->retains == 0) finalizations++; }
struct os_unfair_lock {};
static void os_unfair_lock_lock(os_unfair_lock *) {}
static void os_unfair_lock_unlock(os_unfair_lock *) {}
template<class F> struct Exit { F cleanup; ~Exit() noexcept(false) { cleanup(); } };
template<class F> Exit<F> onExit(F cleanup) { return {cleanup}; }
static constexpr int OutputClass = 1;
struct Output {
    Delegate *sampleBufferDelegate = nullptr;
    dispatch_queue_t sampleBufferCallbackQueue = 0;
    BOOL alwaysDiscardsLateVideoFrames = false;
    int videoSettings = 0;
    static std::vector<std::unique_ptr<Output>> allocations;
    static Output *alloc() { allocations.push_back(std::make_unique<Output>()); return allocations.back().get(); }
    Output *init() { return this; }
    BOOL isKindOfClass(int) { return true; }
    void setSampleBufferDelegate(Delegate *delegate, dispatch_queue_t queue) {
        sampleBufferDelegate = delegate; sampleBufferCallbackQueue = queue;
    }
};
std::vector<std::unique_ptr<Output>> Output::allocations;
static Delegate *delegateOf(Output *output) { return output ? output->sampleBufferDelegate : nullptr; }
struct Outputs {
    std::vector<Output *> values;
    BOOL containsObject(Output *output) { return std::find(values.begin(), values.end(), output) != values.end(); }
    void remove(Output *output) { values.erase(std::remove(values.begin(), values.end(), output), values.end()); }
};
struct Session {
    Outputs storage;
    Outputs *outputs = &storage;
    BOOL allowed = false;
    BOOL canAddOutput(Output *) { return allowed; }
    void beginConfiguration() {}
    void commitConfiguration() {}
    void addOutput(Output *output) { outputs->values.push_back(output); }
    void removeOutput(Output *output) { outputs->remove(output); }
};
struct Item {
    Outputs storage;
    Outputs *outputs = &storage;
    BOOL failNextRemoval = true;
    void removeOutput(Output *output) {
        if (failNextRemoval) { failNextRemoval = false; throw &injected; }
        outputs->remove(output);
    }
};
struct CameraProbe : Delegate {
    Session *_session;
    Output *_ownedOutput = nullptr, *_borrowedOutput = nullptr;
    Delegate *_previousDelegate = nullptr;
    dispatch_queue_t _previousQueue = nullptr, _queue = reinterpret_cast<void *>(1);
    os_unfair_lock _lock;
    CVPixelBufferRef _latest = nullptr;
    BOOL _attached = false, _attachRefused = false;
    NSUInteger _attachmentGeneration = 0;
    explicit CameraProbe(Session *session) : _session(session) {}
    // This legacy fixture has a single unconnected stream. Connection eligibility is an
    // AVFoundation boundary here; CameraStreamProbe executes the exact production helpers.
    BOOL matchesOutput(Output *) { return true; }
    BOOL canCreateOutput() { return true; }
#include "CameraLifecycle.inc"
};
struct PlayerProbe {
    Item *_observedItem;
    Output *_output;
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
    BOOL _attached = true;
    PlayerProbe(Item *item, Output *output, Buffer *buffer) : _observedItem(item), _output(output), _latest(buffer) {}
#include "PlayerLifecycle.inc"
};
static int checks;
static void check(BOOL condition, const char *description) {
    checks++;
    if (!condition) throw std::runtime_error(description);
}
int main() {
    try {
        Session refused;
        CameraProbe camera(&refused);
        auto unchangedGeneration = camera.attachmentGeneration();
        for (int capture = 0; capture < 3; capture++) {
            camera.attach(); // initial discovery
            auto afterWait = camera.attachmentGeneration();
            camera.attach(); // final discovery
            check(camera.attachmentGeneration() == afterWait, "refused camera changes generation during final discovery");
            check(afterWait == unchangedGeneration, "refused camera invalidates nonexistent hook");
            check(refused.outputs->values.empty(), "refused camera adds an output");
        }
        refused.allowed = true;
        camera.attach();
        check(camera.attachmentGeneration() != unchangedGeneration, "successful retry fails to change generation");
        check(refused.outputs->values.size() == 1, "successful retry fails to add exactly one output");
        camera.detach();
        check(refused.outputs->values.empty(), "camera cooldown leaves owned output attached");

        Session borrowed;
        Delegate firstHost, secondHost;
        Output hostOutput;
        hostOutput.setSampleBufferDelegate(&firstHost, reinterpret_cast<void *>(7));
        borrowed.outputs->values.push_back(&hostOutput);
        CameraProbe shared(&borrowed);
        shared.attach();
        auto beforeReplacement = shared.attachmentGeneration();
        hostOutput.setSampleBufferDelegate(&secondHost, reinterpret_cast<void *>(9));
        shared.attach();
        check(shared.attachmentGeneration() != beforeReplacement, "reacquired delegate fails to invalidate readiness");
        shared.detach();
        check(hostOutput.sampleBufferDelegate == &secondHost && hostOutput.sampleBufferCallbackQueue == reinterpret_cast<void *>(9),
              "cooldown loses replacement host delegate or queue");

        Item item;
        Output owned;
        item.outputs->values.push_back(&owned);
        Buffer buffer;
        PlayerProbe player(&item, &owned, &buffer);
        auto before = finalizations;
        BOOL threw = false;
        try { player.detach(); } catch (Exception *) { threw = true; }
        check(threw, "injected removal failure is swallowed");
        check(finalizations == before + 1, "failed detach retains cached buffer");
        check(item.outputs->containsObject(&owned), "fault unexpectedly removed output");
        player.detach();
        check(!item.outputs->containsObject(&owned), "detach retry leaves player output attached");
        player.detach();
        check(finalizations == before + 1, "repeated detach releases buffer twice");
        std::cout << "{\"checks\":" << checks << ",\"passed\":true}" << std::endl;
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << std::endl;
        return 1;
    } catch (Exception *) {
        std::cerr << "unexpected injected framework exception" << std::endl;
        return 1;
    }
}
