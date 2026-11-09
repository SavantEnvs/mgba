// libFuzzer harness: apply an IPS / UPS / BPS patch to a ROM through mGBA's patch loader
// (include/mgba-util/patch.h): loadPatch(), then Patch::outputSize() and Patch::applyPatch(), the same
// sequence GBAApplyPatch (src/gba/gba.c) and GBApplyPatch (src/gb/gb.c) run when a frontend loads a ROM
// with a patch next to it. Input: bytes 0-1 = ROM length (little endian, clamped to what is left),
// then the ROM, then the patch file.
#include <mgba-util/patch.h>
#include <mgba-util/vfs.h>

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Largest output GBAApplyPatch accepts (GBA_SIZE_ROM0); a bigger patched size is rejected before applyPatch.
#define MAX_PATCHED_SIZE 0x2000000

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	if (size < 2) {
		return -1;
	}
	size_t romSize = (size_t) data[0] | ((size_t) data[1] << 8);
	data += 2;
	size -= 2;
	if (romSize > size) {
		romSize = size;
	}

	struct VFile* vf = VFileMemChunk(data + romSize, size - romSize);
	if (!vf) {
		return -1;
	}
	struct Patch patch;
	if (!loadPatch(vf, &patch)) {
		vf->close(vf);
		return -1;
	}

	size_t patchedSize = patch.outputSize(&patch, romSize);
	if (!patchedSize || patchedSize > MAX_PATCHED_SIZE) {
		vf->close(vf);
		return -1;
	}

	// Exactly-sized buffers: applyPatch is told their sizes and must stay inside them.
	uint8_t* rom = malloc(romSize ? romSize : 1);
	uint8_t* out = calloc(patchedSize, 1);
	if (!rom || !out) {
		free(rom);
		free(out);
		vf->close(vf);
		return -1;
	}
	memcpy(rom, data, romSize);

	patch.applyPatch(&patch, rom, romSize, out, patchedSize);

	free(rom);
	free(out);
	vf->close(vf);
	return 0;
}
