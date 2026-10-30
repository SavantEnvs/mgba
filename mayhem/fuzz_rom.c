// libFuzzer harness: the input is a whole ROM image (GBA ROM / ELF, or GB/GBC ROM / GBX), loaded
// through mGBA's own loader and then emulated for a few frames with video and audio running.
// Port of src/platform/test/fuzz-main.c (mgba-fuzz) as an in-process target.
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/gb/core.h>
#include <mgba/gba/core.h>
#include <mgba/internal/gba/gba.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/vfs.h>

#include <stddef.h>
#include <stdint.h>

#if defined(FUZZ_GBA)
#define FUZZ_PLATFORM mPLATFORM_GBA
#define FUZZ_CORE_CREATE GBACoreCreate
#elif defined(FUZZ_GB)
#define FUZZ_PLATFORM mPLATFORM_GB
#define FUZZ_CORE_CREATE GBCoreCreate
#else
#error "define FUZZ_GBA or FUZZ_GB"
#endif

#define FUZZ_FRAMES 4

static void silentLog(struct mLogger* logger, int category, enum mLogLevel level, const char* format, va_list args) {
	(void) logger;
	(void) category;
	(void) level;
	(void) format;
	(void) args;
}

static struct mLogger silentLogger = { .log = silentLog };
static mColor videoBuffer[256 * 256];

int LLVMFuzzerInitialize(int* argc, char*** argv) {
	(void) argc;
	(void) argv;
	mLogSetDefaultLogger(&silentLogger);
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	struct VFile* rom = VFileMemChunk(data, size);
	if (!rom) {
		return -1;
	}
	if (mCoreIsCompatible(rom) != FUZZ_PLATFORM) {
		rom->close(rom);
		return -1;
	}

	struct mCore* core = FUZZ_CORE_CREATE();
	core->init(core);
	mCoreInitConfig(core, "fuzz");
	mCoreConfigSetDefaultValue(&core->config, "idleOptimization", "remove");
	core->setVideoBuffer(core, videoBuffer, 256);

#ifdef FUZZ_GBA
	((struct GBA*) core->board)->hardCrash = false;
#endif

	if (!core->loadROM(core, rom)) {
		rom->close(rom);
		mCoreConfigDeinit(&core->config);
		core->deinit(core);
		return -1;
	}
	core->reset(core);

	int frames;
	for (frames = 0; frames < FUZZ_FRAMES; ++frames) {
		core->runFrame(core);
		mAudioBufferClear(core->getAudioBuffer(core));
	}

	core->unloadROM(core);
	mCoreConfigDeinit(&core->config);
	core->deinit(core);
	return 0;
}
