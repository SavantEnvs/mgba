// libFuzzer harness: overlay the input onto a valid savestate of a tiny synthetic ROM, load it
// through mCoreLoadStateNamed and emulate a few frames. The first 4 input bytes pick the overlay
// offset (same idea as the -O/-V savestate overlay of src/platform/test/fuzz-main.c).
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/core/serialize.h>
#include <mgba/gb/core.h>
#include <mgba/gba/core.h>
#include <mgba/internal/gba/gba.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/memory.h>
#include <mgba-util/vfs.h>

#include <stdlib.h>
#include <string.h>

#if defined(FUZZ_GBA)
#define FUZZ_CORE_CREATE GBACoreCreate
#define ROM_SIZE 0x400
#elif defined(FUZZ_GB)
#define FUZZ_CORE_CREATE GBCoreCreate
#define ROM_SIZE 0x8000
#else
#error "define FUZZ_GBA or FUZZ_GB"
#endif

#define FUZZ_FRAMES 3

static void silentLog(struct mLogger* logger, int category, enum mLogLevel level, const char* format, va_list args) {
	(void) logger;
	(void) category;
	(void) level;
	(void) format;
	(void) args;
}

static struct mLogger silentLogger = { .log = silentLog };
static mColor videoBuffer[256 * 256];

static const uint8_t nintendoLogo[48] = {
	0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
	0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
	0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
};

static struct VFile* makeRom(void) {
	uint8_t* buffer = calloc(ROM_SIZE, 1);
#ifdef FUZZ_GBA
	// b . (spin), then the fixed-value byte the header checks expect
	buffer[0] = 0xFE;
	buffer[1] = 0xFF;
	buffer[2] = 0xFF;
	buffer[3] = 0xEA;
	buffer[0xB2] = 0x96;
#else
	// jp 0x0150 at the entry point, logo, then a spin loop (jr -2)
	buffer[0x100] = 0xC3;
	buffer[0x101] = 0x50;
	buffer[0x102] = 0x01;
	memcpy(&buffer[0x104], nintendoLogo, sizeof(nintendoLogo));
	buffer[0x150] = 0x18;
	buffer[0x151] = 0xFE;
#endif
	struct VFile* vf = VFileMemChunk(buffer, ROM_SIZE);
	free(buffer);
	return vf;
}

int LLVMFuzzerInitialize(int* argc, char*** argv) {
	(void) argc;
	(void) argv;
	mLogSetDefaultLogger(&silentLogger);
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	if (size < 5) {
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

	struct VFile* rom = makeRom();
	if (!rom || !core->loadROM(core, rom)) {
		abort();
	}
	core->reset(core);
	core->runFrame(core);
	mAudioBufferClear(core->getAudioBuffer(core));

	size_t stateSize = core->stateSize(core);
	void* state = anonymousMemoryMap(stateSize);
	if (!core->saveState(core, state)) {
		abort();
	}

	uint32_t offset;
	memcpy(&offset, data, sizeof(offset));
	offset %= stateSize;
	size_t overlay = size - sizeof(offset);
	if (overlay > stateSize - offset) {
		overlay = stateSize - offset;
	}
	memcpy((uint8_t*) state + offset, data + sizeof(offset), overlay);

	struct VFile* stateFile = VFileFromMemory(state, stateSize);
	bool loaded = mCoreLoadStateNamed(core, stateFile, SAVESTATE_ALL);
	stateFile->close(stateFile);
	mappedMemoryFree(state, stateSize);

	if (loaded) {
		int frames;
		for (frames = 0; frames < FUZZ_FRAMES; ++frames) {
			core->runFrame(core);
			mAudioBufferClear(core->getAudioBuffer(core));
		}
	}

	core->unloadROM(core);
	mCoreConfigDeinit(&core->config);
	core->deinit(core);
	return loaded ? 0 : -1;
}
