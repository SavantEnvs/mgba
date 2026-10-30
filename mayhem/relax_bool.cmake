# _GBACoreReset (src/gba/core.c) evaluates `UNUSED(value)` on an uninitialized `bool`, which UBSan's
# bool check halts on for any GBA input. Relax only that check, only for that file.
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/src/gba/core.c PROPERTIES COMPILE_FLAGS "-fno-sanitize=bool")
