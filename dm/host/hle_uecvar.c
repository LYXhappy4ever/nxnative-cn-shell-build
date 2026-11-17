// Unreal console variables found by their registered names (dm/tools/ue_cvar.py; main's fixups UE_CVAR:<name>).
// Supports texture streaming pool adjustment (DM_UE_TEXTURE_POOL) and live quality/resolution presets
// (DM_QUALITY_PRESET, DM_UE_RES_SCALE) toggled at runtime from the iOS in-game menu.
#include "hle.h"
#include <mach/mach.h>
#include <TargetConditionals.h>

static int rd(uint64_t a, void *out, size_t n) {
    vm_size_t got = 0;
    return a >= 0x1000 && vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)out, &got) == KERN_SUCCESS && got == n;
}

uint64_t dm_ue_cvar(const char *name) {
    for (int i = 0; i < g_nmod; i++) {
        if (!strcmp(g_mod[i].name, "main")) {
            for (int k = 0; k < g_mod[i].n_ue_cvar; k++) {
                if (!strcmp(g_mod[i].ue_cvar[k].name, name)) return g_mod[i].ue_cvar[k].off;
            }
        }
    }
    return 0;
}

static uint8_t *main_base(void) {
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) return g_mod[i].base;
    return NULL;
}

static void write_cvar_i32(uint8_t *base, uint64_t obj_off, const char *name, int32_t want, int *nlog) {
    if (!base || !obj_off) return;
    uint64_t val = 0;
    if (!rd((uint64_t)(uintptr_t)(base + obj_off + 0x10), &val, sizeof val) || !val) return;
    for (int c = 0; c < 2; c++) {
        int32_t cur = 0, *p = (int32_t *)(uintptr_t)(val + 4 * (uint64_t)c);
        if (!rd((uint64_t)(uintptr_t)p, &cur, sizeof cur) || cur == want) continue;
        dm_guest_write_prepare(p, sizeof *p);
        __atomic_store_n(p, want, __ATOMIC_RELAXED);
        if (*nlog < 16) {
            (*nlog)++;
            LOG("main: Unreal %s (%s) %d -> %d", name, c ? "render" : "game", cur, want);
        }
    }
}

static void write_cvar_f32(uint8_t *base, uint64_t obj_off, const char *name, float want, int *nlog) {
    if (!base || !obj_off) return;
    uint64_t val = 0;
    if (!rd((uint64_t)(uintptr_t)(base + obj_off + 0x10), &val, sizeof val) || !val) return;
    uint32_t want_bits = 0;
    memcpy(&want_bits, &want, sizeof want_bits);
    for (int c = 0; c < 2; c++) {
        float cur = 0.0f;
        uint32_t cur_bits = 0, *p = (uint32_t *)(uintptr_t)(val + 4 * (uint64_t)c);
        if (!rd((uint64_t)(uintptr_t)p, &cur_bits, sizeof cur_bits)) continue;
        memcpy(&cur, &cur_bits, sizeof cur);
        if (cur_bits == want_bits || (cur == want)) continue;
        dm_guest_write_prepare(p, sizeof *p);
        __atomic_store_n(p, want_bits, __ATOMIC_RELAXED);
        if (*nlog < 16) {
            (*nlog)++;
            LOG("main: Unreal %s (%s) %.2f -> %.2f", name, c ? "render" : "game", cur, want);
        }
    }
}

static int g_ue_cvar_reinit = 0;
void dm_ue_cvar_refresh(void) {
    __atomic_store_n(&g_ue_cvar_reinit, 1, __ATOMIC_RELEASE);
}

enum {
    CV_SHADOW = 0, CV_PP, CV_FX, CV_MB, CV_AO, CV_SSR, CV_BLOOM,
    CV_DYN_OP, CV_DYN_BUDGET, CV_DYN_MIN, CV_DYN_MAX, CV_SCREEN_PCT,
    CV_POOL, CV_COUNT
};

static const char *const k_cvar_names[CV_COUNT] = {
    "sg.ShadowQuality",
    "sg.PostProcessQuality",
    "sg.EffectsQuality",
    "r.MotionBlurQuality",
    "r.AmbientOcclusionLevels",
    "r.SSR.Quality",
    "r.BloomQuality",
    "r.DynamicRes.OperationMode",
    "r.DynamicRes.FrameTimeBudget",
    "r.DynamicRes.MinScreenPercentage",
    "r.DynamicRes.MaxScreenPercentage",
    "r.ScreenPercentage",
    "r.Streaming.PoolSize",
};

void dm_ue_cvar_tick(void) {
    static int inited = 0, has_any = 0, nlog_pool = 0, nlog_q = 0;
    static uint64_t offs[CV_COUNT];
    static int pool_target = 0;
    static const char *pool_src = NULL;
    static int q_active = 0; // 0=game default, 1=smooth, 2=balanced, 3=high, 4=ultra
    static int res_mode = 0; // 0=untouched, 1=auto dynamic, 2=fixed percent
    static float res_pct = 100.0f;
    static uint64_t tick_n = 0;

    int force = __atomic_exchange_n(&g_ue_cvar_reinit, 0, __ATOMIC_ACQUIRE);
    if (!inited || force) {
        if (!inited) {
            inited = 1;
            for (int i = 0; i < CV_COUNT; i++) {
                offs[i] = dm_ue_cvar(k_cvar_names[i]);
                if (offs[i]) has_any = 1;
            }
        }
        const char *pe = getenv("DM_UE_TEXTURE_POOL");
        pool_target = pe ? atoi(pe) : TARGET_OS_IPHONE ? 0 : DM_GAME_UE_TEXTURE_POOL;
        pool_src = pe ? "DM_UE_TEXTURE_POOL" : "game profile ue_texture_pool";

        const char *qp = getenv("DM_QUALITY_PRESET");
        if (qp && !strcmp(qp, "smooth")) q_active = 1;
        else if (qp && !strcmp(qp, "balanced")) q_active = 2;
        else if (qp && !strcmp(qp, "high")) q_active = 3;
        else if (qp && !strcmp(qp, "ultra")) q_active = 4;
        else q_active = 0;

        const char *rs = getenv("DM_UE_RES_SCALE");
        if (!rs || !*rs || !strcmp(rs, "game")) {
            res_mode = 0;
        } else if (!strcmp(rs, "auto") || !strcmp(rs, "0")) {
            res_mode = 1;
            res_pct = 100.0f;
        } else {
            double v = strtod(rs, NULL);
            if (v > 0.25 && v <= 2.0) {
                res_mode = 2;
                res_pct = (float)(v * 100.0);
            } else {
                res_mode = 0;
            }
        }
        if (force) {
            nlog_q = 0;
            LOG("main: Unreal quality=%s, res_scale=%s", qp ? qp : "game", rs ? rs : "game");
        }
        tick_n = 0;
    }

    if (!has_any) return;
    if (!force && (tick_n++ % 30) != 0) return;

    uint8_t *base = main_base();
    if (!base) return;

    if (pool_target > 0 && offs[CV_POOL]) {
        uint64_t val = 0;
        if (rd((uint64_t)(uintptr_t)(base + offs[CV_POOL] + 0x10), &val, sizeof val) && val) {
            for (int c = 0; c < 2; c++) {
                int32_t cur = 0, *p = (int32_t *)(uintptr_t)(val + 4 * (uint64_t)c);
                if (!rd((uint64_t)(uintptr_t)p, &cur, sizeof cur) || cur <= 0 || cur >= pool_target) continue;
                dm_guest_write_prepare(p, sizeof *p);
                __atomic_store_n(p, pool_target, __ATOMIC_RELAXED);
                if (nlog_pool < 8) {
                    nlog_pool++;
                    LOG("main: Unreal r.Streaming.PoolSize (%s thread) %d -> %d MB (%s)", c ? "render" : "game", cur, pool_target, pool_src);
                }
            }
        }
    }

    if (q_active == 1) {
        // 流畅优先：降阴影/后处理/特效/SSR/AO/动态模糊，保留柔和泛光，并把动态分辨率预算提前到 26.5ms
        write_cvar_i32(base, offs[CV_SHADOW], k_cvar_names[CV_SHADOW], 0, &nlog_q);
        write_cvar_i32(base, offs[CV_PP], k_cvar_names[CV_PP], 1, &nlog_q);
        write_cvar_i32(base, offs[CV_FX], k_cvar_names[CV_FX], 1, &nlog_q);
        write_cvar_i32(base, offs[CV_MB], k_cvar_names[CV_MB], 0, &nlog_q);
        write_cvar_i32(base, offs[CV_AO], k_cvar_names[CV_AO], 0, &nlog_q);
        write_cvar_i32(base, offs[CV_SSR], k_cvar_names[CV_SSR], 0, &nlog_q);
        write_cvar_i32(base, offs[CV_BLOOM], k_cvar_names[CV_BLOOM], 4, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_BUDGET], k_cvar_names[CV_DYN_BUDGET], 26.5f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MIN], k_cvar_names[CV_DYN_MIN], 50.0f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MAX], k_cvar_names[CV_DYN_MAX], 85.0f, &nlog_q);
    } else if (q_active == 2) {
        // 均衡画质：保留基础阴影、AO 与低档反射，动态分辨率 60%-95%
        write_cvar_i32(base, offs[CV_SHADOW], k_cvar_names[CV_SHADOW], 1, &nlog_q);
        write_cvar_i32(base, offs[CV_PP], k_cvar_names[CV_PP], 2, &nlog_q);
        write_cvar_i32(base, offs[CV_FX], k_cvar_names[CV_FX], 2, &nlog_q);
        write_cvar_i32(base, offs[CV_MB], k_cvar_names[CV_MB], 0, &nlog_q);
        write_cvar_i32(base, offs[CV_AO], k_cvar_names[CV_AO], 1, &nlog_q);
        write_cvar_i32(base, offs[CV_SSR], k_cvar_names[CV_SSR], 1, &nlog_q);
        write_cvar_i32(base, offs[CV_BLOOM], k_cvar_names[CV_BLOOM], 4, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_BUDGET], k_cvar_names[CV_DYN_BUDGET], 29.0f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MIN], k_cvar_names[CV_DYN_MIN], 60.0f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MAX], k_cvar_names[CV_DYN_MAX], 95.0f, &nlog_q);
    } else if (q_active == 3) {
        // 原版高画质
        write_cvar_i32(base, offs[CV_SHADOW], k_cvar_names[CV_SHADOW], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_PP], k_cvar_names[CV_PP], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_FX], k_cvar_names[CV_FX], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_MB], k_cvar_names[CV_MB], 4, &nlog_q);
        write_cvar_i32(base, offs[CV_AO], k_cvar_names[CV_AO], -1, &nlog_q);
        write_cvar_i32(base, offs[CV_SSR], k_cvar_names[CV_SSR], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_BLOOM], k_cvar_names[CV_BLOOM], 4, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_BUDGET], k_cvar_names[CV_DYN_BUDGET], 33.33f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MIN], k_cvar_names[CV_DYN_MIN], 75.0f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MAX], k_cvar_names[CV_DYN_MAX], 100.0f, &nlog_q);
    } else if (q_active == 4) {
        // 极致画质
        write_cvar_i32(base, offs[CV_SHADOW], k_cvar_names[CV_SHADOW], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_PP], k_cvar_names[CV_PP], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_FX], k_cvar_names[CV_FX], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_MB], k_cvar_names[CV_MB], 4, &nlog_q);
        write_cvar_i32(base, offs[CV_AO], k_cvar_names[CV_AO], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_SSR], k_cvar_names[CV_SSR], 3, &nlog_q);
        write_cvar_i32(base, offs[CV_BLOOM], k_cvar_names[CV_BLOOM], 5, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_BUDGET], k_cvar_names[CV_DYN_BUDGET], 33.33f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MIN], k_cvar_names[CV_DYN_MIN], 90.0f, &nlog_q);
        write_cvar_f32(base, offs[CV_DYN_MAX], k_cvar_names[CV_DYN_MAX], 100.0f, &nlog_q);
    }

    if (res_mode == 1) {
        write_cvar_i32(base, offs[CV_DYN_OP], k_cvar_names[CV_DYN_OP], 1, &nlog_q);
        write_cvar_f32(base, offs[CV_SCREEN_PCT], k_cvar_names[CV_SCREEN_PCT], 100.0f, &nlog_q);
    } else if (res_mode == 2) {
        write_cvar_i32(base, offs[CV_DYN_OP], k_cvar_names[CV_DYN_OP], 0, &nlog_q);
        write_cvar_f32(base, offs[CV_SCREEN_PCT], k_cvar_names[CV_SCREEN_PCT], res_pct, &nlog_q);
    }
}
