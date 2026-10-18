"""Validate/remap legacy dyld segment ordinals without executing an image.

Removing __PAGEZERO changes segment ordinals, even though VM addresses and
section ordinals stay unchanged. Never search/replace raw bytes: ULEB/SLEB and
symbol strings may contain bytes that look like opcodes.
"""


def leb(data, position, signed=False):
    value = shift = 0
    for index in range(10):
        if position >= len(data):
            raise ValueError("Truncated dyld variable integer")
        byte = data[position]
        position += 1
        payload = byte & 0x7F
        if index == 9 and payload not in ((0, 0x7F) if signed else (0, 1)):
            raise ValueError("Overflowing dyld variable integer")
        value |= payload << shift
        shift += 7
        if not byte & 0x80:
            if signed and byte & 0x40:
                value -= 1 << shift
            return value, position
    raise ValueError("Overflowing dyld variable integer")


def remap_stream(data, kind, segments, removed=0):
    if kind not in ("rebase", "bind", "weak", "lazy"):
        raise ValueError("Unknown dyld stream kind")
    result = bytearray(data)
    position = 0
    segment = None
    offset = 0
    width = 8
    symbol = False
    done = not data
    changes = 0

    def advance(amount, check_bounds=True):
        nonlocal offset
        if segment is None:
            raise ValueError("Dyld address used before segment selection")
        # dyld uses uint64 address arithmetic. Legacy bind streams encode
        # backward offsets as large unsigned ULEBs; preserve that wrapping
        # while requiring each resulting location to stay inside its segment.
        offset = (offset + amount) & ((1 << 64) - 1)
        if check_bounds and offset > segments[segment]["vmsize"]:
            raise ValueError("Dyld segment offset outside bounds")

    def fix(count=1, skip=0):
        nonlocal offset
        if segment is None:
            raise ValueError("Dyld fixup used before segment selection")
        if kind != "rebase" and not symbol:
            raise ValueError("Dyld bind used before symbol selection")
        if count:
            last = offset + (count - 1) * (8 + skip)
            target = segments[segment]
            if last + width > target["vmsize"]:
                raise ValueError("Dyld fixup outside segment bounds")
            if not target["initprot"] & 2:
                raise ValueError("Dyld fixup targets a nonwritable segment")
        # Opcode address increments use the image pointer size (8), including
        # TEXT_ABSOLUTE32/PCREL32 writes whose storage width is only 4. The
        # unused address after the last write may lie beyond the segment.
        advance(count * (8 + skip), check_bounds=False)

    while position < len(data):
        opcode_position = position
        byte = data[position]
        position += 1
        opcode, immediate = byte & 0xF0, byte & 0x0F
        done = False
        if opcode == 0:
            if immediate:
                raise ValueError("Malformed dyld DONE opcode")
            done = True
            if kind != "lazy":
                if any(data[position:]):
                    raise ValueError("Nonzero data after terminal dyld DONE")
                break
            segment, offset, width, symbol = None, 0, 8, False
            continue
        segment_opcode = 0x20 if kind == "rebase" else 0x70
        if opcode == segment_opcode:
            if immediate >= len(segments) or immediate == removed:
                raise ValueError("Dyld references missing or removed segment 0")
            segment = immediate
            offset, position = leb(data, position)
            if offset > segments[segment]["vmsize"]:
                raise ValueError("Dyld segment offset outside bounds")
            ordinal = immediate - (immediate > removed)
            result[opcode_position] = opcode | ordinal
            changes += 1
            continue
        if kind == "rebase":
            if opcode == 0x10:
                if immediate not in (1, 2, 3):
                    raise ValueError("Unsupported dyld rebase type")
                width = 8 if immediate == 1 else 4
            elif opcode == 0x30:
                if immediate:
                    raise ValueError("Malformed rebase ADD_ADDR opcode")
                amount, position = leb(data, position)
                advance(amount)
            elif opcode == 0x40:
                advance(immediate * 8)
            elif opcode == 0x50:
                fix(immediate)
            elif opcode == 0x60:
                if immediate:
                    raise ValueError("Malformed rebase count opcode")
                count, position = leb(data, position)
                fix(count)
            elif opcode == 0x70:
                if immediate:
                    raise ValueError("Malformed rebase skip opcode")
                skip, position = leb(data, position)
                fix(1, skip)
            elif opcode == 0x80:
                if immediate:
                    raise ValueError("Malformed rebase repeat opcode")
                count, position = leb(data, position)
                skip, position = leb(data, position)
                fix(count, skip)
            else:
                raise ValueError("Unsupported dyld rebase opcode")
        else:
            if opcode == 0x10:  # dylib ordinal is unrelated to segment ordinal.
                pass
            elif opcode == 0x20:
                if immediate:
                    raise ValueError("Malformed bind library opcode")
                _, position = leb(data, position)
            elif opcode == 0x30:
                if immediate not in (0, 13, 14, 15):
                    raise ValueError("Unsupported special dylib ordinal")
            elif opcode == 0x40:
                end = data.find(b"\0", position)
                if end < 0:
                    raise ValueError("Unterminated dyld bind symbol")
                if end == position:
                    raise ValueError("Empty dyld bind symbol")
                position, symbol = end + 1, True
            elif opcode == 0x50:
                if immediate not in (1, 2, 3):
                    raise ValueError("Unsupported dyld bind type")
                width = 8 if immediate == 1 else 4
            elif opcode == 0x60:
                if immediate:
                    raise ValueError("Malformed bind addend opcode")
                _, position = leb(data, position, signed=True)
            elif opcode == 0x80:
                if immediate:
                    raise ValueError("Malformed bind ADD_ADDR opcode")
                amount, position = leb(data, position)
                advance(amount)
            elif opcode == 0x90:
                if immediate:
                    raise ValueError("Malformed DO_BIND opcode")
                fix()
            elif opcode == 0xA0:
                if immediate:
                    raise ValueError("Malformed bind skip opcode")
                skip, position = leb(data, position)
                fix(1, skip)
            elif opcode == 0xB0:
                fix(1, immediate * 8)
            elif opcode == 0xC0:
                if immediate:
                    raise ValueError("Malformed bind repeat opcode")
                count, position = leb(data, position)
                skip, position = leb(data, position)
                fix(count, skip)
            else:
                # Threaded binds/chained fixups require a different structural
                # transformation; never silently patch their embedded words.
                raise ValueError(
                    "Unsupported dyld bind opcode (including threaded binds)"
                )
    if not done:
        raise ValueError("Dyld stream lacks terminal DONE")
    return bytes(result), changes
