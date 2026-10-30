// libFuzzer harness: parse a text-table (.tbl) and decode a byte stream with it. Port of
// src/platform/test/tbl-fuzz-main.c (tbl-fuzz) as an in-process target. The first two input bytes
// give the length of the table, the rest is the byte stream to decode.
#include <mgba-util/text-codec.h>
#include <mgba-util/vfs.h>

#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
	if (size < 2) {
		return -1;
	}
	size_t tblSize = (size_t) data[0] | ((size_t) data[1] << 8);
	data += 2;
	size -= 2;
	if (tblSize > size) {
		tblSize = size;
	}

	struct VFile* tbl = VFileMemChunk(data, tblSize);
	if (!tbl) {
		return -1;
	}
	struct TextCodec codec;
	bool loaded = TextCodecLoadTBL(&codec, tbl, true);
	tbl->close(tbl);
	if (!loaded) {
		TextCodecDeinit(&codec);
		return -1;
	}

	struct TextCodecIterator iter;
	TextCodecStartDecode(&codec, &iter);
	uint8_t lineBuffer[128];
	size_t i;
	for (i = tblSize; i < size; ++i) {
		TextCodecAdvance(&iter, data[i], lineBuffer, sizeof(lineBuffer));
	}
	TextCodecFinish(&iter, lineBuffer, sizeof(lineBuffer));

	TextCodecDeinit(&codec);
	return 0;
}
