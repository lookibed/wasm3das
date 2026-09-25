/*
 * binjgb (Game Boy / Game Boy Color emulator) as an eden_game guest.
 *
 * The emulator core is upstream binjgb (guests/binjgb/upstream, MIT), the
 * same sources and EmulatorInit as the reference fixture of the Spider
 * project (tests/manual/real-world-binjgb/src/module.c), so the frames match
 * its wasmtime baselines digest for digest.
 *
 * ABI use:
 *   eden_asset  "rom": the cartridge image
 *   eden_input  pad 0, sampled once at the start of every emulated frame
 *               (BUTTON_* bits are binjgb's mask order: A B Select Start
 *               Right Left Up Down)
 *   eden_video  one RGBA8 160x144 frame per emulated frame
 *   eden_audio  one stereo unsigned 8-bit stream at 44100 Hz
 *   eden_core   log, time_us for the step budget
 *   eden_storage  "battery": battery-backed cartridge RAM
 *
 * eden_step runs the emulator in slices of SLICE_TICKS and returns when the
 * budget is spent (the frame continues in the next step) or right after a
 * frame was presented. Where a step ends never changes the emulation: input
 * is sampled at frame starts only.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include "emulator.h"

#include "eden/eden_game.h"

#define AUDIO_FREQUENCY 44100
#define AUDIO_FRAMES 2048
#define SLICE_TICKS (PPU_FRAME_TICKS / 16)
#define STATE_MAGIC 0x45444A42u /* "BJDE" */

typedef struct GuestState {
    uint32_t magic;
    int32_t frame;         /* frames presented */
    int32_t in_frame;      /* 1 once the current frame sampled its input */
    int32_t buttons;       /* the mask of the current frame */
    uint64_t until_ticks;  /* the end of the current frame (reference loop) */
} GuestState;

static Emulator *g_emu;
static int32_t g_stream;
static GuestState g;
static JoypadButtons g_joypad;

static void apply_mask(JoypadButtons *b, int32_t mask) {
    b->A = (mask & EDEN_INPUT_BUTTON_A) ? TRUE : FALSE;
    b->B = (mask & EDEN_INPUT_BUTTON_B) ? TRUE : FALSE;
    b->select = (mask & EDEN_INPUT_BUTTON_SELECT) ? TRUE : FALSE;
    b->start = (mask & EDEN_INPUT_BUTTON_START) ? TRUE : FALSE;
    b->right = (mask & EDEN_INPUT_BUTTON_RIGHT) ? TRUE : FALSE;
    b->left = (mask & EDEN_INPUT_BUTTON_LEFT) ? TRUE : FALSE;
    b->up = (mask & EDEN_INPUT_BUTTON_UP) ? TRUE : FALSE;
    b->down = (mask & EDEN_INPUT_BUTTON_DOWN) ? TRUE : FALSE;
}

static void joypad_callback(JoypadButtons *buttons, void *user_data) {
    (void)user_data;
    *buttons = g_joypad;
}

int32_t eden_abi_version(void) {
    return EDEN_GAME_VERSION;
}

/* Battery-backed cartridge RAM lives in the eden_storage blob "battery"
 * (the host picks a namespace per ROM). It is loaded at init and saved when
 * the game stopped changing it for BATTERY_QUIET_FRAMES, and at shutdown. */
#define BATTERY_BLOB "battery"
#define BATTERY_QUIET_FRAMES 60

static int g_battery_dirty;
static int32_t g_battery_changed_frame;

static void battery_load(void) {
    FileData fd;
    emulator_init_ext_ram_file_data(g_emu, &fd);
    if (fd.size > 0 && eden_storage_size_z(BATTERY_BLOB) == (int32_t)fd.size) {
        if (eden_storage_read_z(BATTERY_BLOB, 0, fd.data, (int32_t)fd.size) == (int32_t)fd.size &&
            emulator_read_ext_ram(g_emu, &fd) == OK) {
            printf("binjgb: battery RAM restored (%d bytes)\n", (int)fd.size);
        } else {
            eden_core_log_z(EDEN_CORE_LOG_WARN, "binjgb: battery RAM blob unreadable, starting empty");
        }
    }
    free(fd.data);
}

static void battery_save(void) {
    FileData fd;
    emulator_init_ext_ram_file_data(g_emu, &fd);
    if (fd.size > 0 && emulator_write_ext_ram(g_emu, &fd) == OK) {
        int32_t r = eden_storage_write_z(BATTERY_BLOB, fd.data, (int32_t)fd.size);
        if (r == EDEN_STORAGE_OK) {
            g_battery_dirty = 0;
        } else {
            printf("binjgb: saving battery RAM failed (%d)\n", (int)r);
        }
    }
    free(fd.data);
}

static void battery_after_frame(void) {
    if (emulator_was_ext_ram_updated(g_emu)) {
        g_battery_dirty = 1;
        g_battery_changed_frame = g.frame;
    }
    if (g_battery_dirty && g.frame - g_battery_changed_frame >= BATTERY_QUIET_FRAMES) {
        battery_save();
    }
}

int32_t eden_init(void) {
    int32_t size = eden_asset_size_z("rom");
    if (size <= 0) {
        eden_core_log_z(EDEN_CORE_LOG_ERROR, "binjgb: no asset \"rom\"");
        return 1;
    }
    size_t aligned = ALIGN_UP((size_t)size, MINIMUM_ROM_SIZE);
    uint8_t *rom = (uint8_t *)calloc(1, aligned);
    if (!rom) {
        eden_core_log_z(EDEN_CORE_LOG_ERROR, "binjgb: out of memory for the ROM");
        return 2;
    }
    if (eden_asset_read_z("rom", 0, rom, size) != size) {
        free(rom);
        eden_core_log_z(EDEN_CORE_LOG_ERROR, "binjgb: short ROM read");
        return 3;
    }
    /* emulator_new takes the ROM buffer: it may realloc it, and
     * emulator_delete frees it (also when emulator_new fails) */
    EmulatorInit init;
    ZERO_MEMORY(init);
    init.rom.data = rom;
    init.rom.size = aligned;
    init.audio_frequency = AUDIO_FREQUENCY;
    init.audio_frames = AUDIO_FRAMES;
    init.random_seed = 0xcabba6e5u;
    init.builtin_palette = 0;
    init.force_dmg = FALSE;
    init.cgb_color_curve = CGB_COLOR_CURVE_NONE;
    g_emu = emulator_new(&init);
    if (!g_emu) {
        eden_core_log_z(EDEN_CORE_LOG_ERROR, "binjgb: emulator_new failed (bad ROM?)");
        return 4;
    }
    ZERO_MEMORY(g_joypad);
    emulator_set_joypad_callback(g_emu, joypad_callback, 0);
    battery_load();
    g_stream = eden_audio_open(AUDIO_FREQUENCY, 2);
    if (g_stream <= 0) {
        eden_core_log_z(EDEN_CORE_LOG_WARN, "binjgb: no audio stream, running silent");
        g_stream = 0;
    }
    memset(&g, 0, sizeof g);
    g.magic = STATE_MAGIC;
    printf("binjgb: ROM %d bytes, audio stream %d\n", (int)size, (int)g_stream);
    return 0;
}

/* binjgb appends to its audio buffer across emulator_run_until calls and
 * rewinds it at the start of the call after one that reported
 * EMULATOR_EVENT_AUDIO_BUFFER_FULL; only the frames added since the last push
 * are sent */
static u32 g_audio_pushed;
static int g_audio_rewind;

static void push_audio(EmulatorEvent event) {
    AudioBuffer *ab = emulator_get_audio_buffer(g_emu);
    u32 frames = audio_buffer_get_frames(ab);
    if (g_stream > 0 && frames > g_audio_pushed) {
        eden_audio_push(g_stream, ab->data + g_audio_pushed * 2, (int32_t)((frames - g_audio_pushed) * 2),
                        EDEN_AUDIO_SAMPLE_U8);
    }
    g_audio_pushed = frames;
    g_audio_rewind = (event & EMULATOR_EVENT_AUDIO_BUFFER_FULL) != 0;
}

int32_t eden_step(int32_t budget_us) {
    if (!g_emu) {
        return EDEN_GAME_STEP_ERROR;
    }
    int64_t start = eden_core_time_us();
    if (!g.in_frame) {
        g.buttons = eden_input_buttons(0);
        ZERO_MEMORY(g_joypad);
        apply_mask(&g_joypad, g.buttons);
        g.until_ticks = emulator_get_ticks(g_emu) + PPU_FRAME_TICKS;
        g.in_frame = 1;
    }
    for (;;) {
        Ticks now = emulator_get_ticks(g_emu);
        Ticks target = now + SLICE_TICKS < g.until_ticks ? now + SLICE_TICKS : g.until_ticks;
        if (g_audio_rewind) {
            g_audio_pushed = 0; /* this call rewinds the buffer */
        }
        EmulatorEvent event = emulator_run_until(g_emu, target);
        push_audio(event);
        if (event & EMULATOR_EVENT_NEW_FRAME) {
            const RGBA *pixels = *emulator_get_frame_buffer(g_emu);
            eden_video_present(pixels, SCREEN_WIDTH * SCREEN_HEIGHT * 4, SCREEN_WIDTH, SCREEN_HEIGHT,
                               SCREEN_WIDTH * 4, EDEN_VIDEO_FORMAT_RGBA8);
            g.frame++;
            g.in_frame = 0;
            battery_after_frame();
            return EDEN_GAME_STEP_FRAME;
        }
        if (event & EMULATOR_EVENT_INVALID_OPCODE) {
            eden_core_log_z(EDEN_CORE_LOG_ERROR, "binjgb: invalid opcode");
            return EDEN_GAME_STEP_ERROR;
        }
        if (emulator_get_ticks(g_emu) >= g.until_ticks) {
            /* the reference loop: no frame within PPU_FRAME_TICKS (LCD off) */
            g.until_ticks += PPU_FRAME_TICKS;
        }
        if (eden_core_time_us() - start >= budget_us) {
            return 0;
        }
    }
}

void eden_shutdown(void) {
    if (g_stream > 0) {
        eden_audio_close(g_stream);
        g_stream = 0;
    }
    if (g_emu) {
        if (g_battery_dirty) {
            battery_save();
        }
        emulator_delete(g_emu); /* frees the ROM buffer too */
        g_emu = 0;
    }
}

/* snapshot = GuestState then binjgb's EmulatorState */

static size_t emulator_state_size(void) {
    FileData fd;
    emulator_init_state_file_data(&fd);
    size_t size = fd.size;
    free(fd.data);
    return size;
}

int32_t eden_state_size(void) {
    if (!g_emu) {
        return -1;
    }
    return (int32_t)(sizeof(GuestState) + emulator_state_size());
}

int32_t eden_state_save(int32_t dst, int32_t cap) {
    if (!g_emu) {
        return -1;
    }
    size_t es = emulator_state_size();
    size_t total = sizeof(GuestState) + es;
    if (cap < 0 || (size_t)cap < total) {
        return -2;
    }
    uint8_t *out = (uint8_t *)(uintptr_t)dst;
    memcpy(out, &g, sizeof g);
    FileData fd;
    fd.data = out + sizeof g;
    fd.size = es;
    if (emulator_write_state(g_emu, &fd) != OK) {
        return -3;
    }
    return (int32_t)total;
}

int32_t eden_state_load(const void *snapshot, int32_t snapshot_len) {
    if (!g_emu) {
        return -1;
    }
    size_t es = emulator_state_size();
    if (snapshot_len < 0 || (size_t)snapshot_len != sizeof(GuestState) + es) {
        eden_core_log_z(EDEN_CORE_LOG_ERROR, "binjgb: snapshot has the wrong size");
        return -2;
    }
    GuestState saved;
    memcpy(&saved, snapshot, sizeof saved);
    if (saved.magic != STATE_MAGIC) {
        eden_core_log_z(EDEN_CORE_LOG_ERROR, "binjgb: not a binjgb snapshot");
        return -3;
    }
    FileData fd;
    fd.data = (u8 *)snapshot + sizeof saved;
    fd.size = es;
    if (emulator_read_state(g_emu, &fd) != OK) {
        return -4;
    }
    g = saved;
    /* the audio buffer is not part of the snapshot: continue from its end */
    g_audio_pushed = audio_buffer_get_frames(emulator_get_audio_buffer(g_emu));
    g_audio_rewind = 0;
    ZERO_MEMORY(g_joypad);
    apply_mask(&g_joypad, g.buttons);
    return 0;
}
