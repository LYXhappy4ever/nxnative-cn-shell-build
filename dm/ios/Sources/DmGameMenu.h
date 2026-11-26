// The in-game menu: GameMenu.swift builds it, the gamepad's menu button at the top centre or a physical controller shortcut (-/+ or L3+R3) opens it (DmGamepad.m).
// It holds the controller assignment/layout and the launcher settings the running game takes at once (front_ios.m dm_setting_live).
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
void *dm_game_menu(void);   // legacy UIMenu pointer (kept for ABI compatibility)
void dm_game_menu_toggle(void);   // GameMenu.swift: open/close custom touch+gamepad menu overlay
void dm_game_menu_nav(int dirX, int dirY, bool a, bool b);   // GameMenu.swift: handle gamepad navigation
void dm_game_menu_set_open(bool open);   // DmGamepad.m: track open state so physical pads route to menu
bool dm_game_menu_is_open(void);

int dm_pad_layout(void);   // DmGamepad.m: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
bool dm_pad_layout_offered(int layout);   // Tap only in handheld mode
void dm_pad_layout_set(int layout);   // releases every touch first, and is saved for the next start
void dm_gamepad_touch_feedback(bool on);   // DM_TOUCH_HAPTICS
bool dm_setting_live(const char *env, const char *value);   // front_ios.m: value NULL asks whether the running game takes env at once; otherwise applies it
void dm_set_game_speed(int pct);
int dm_get_game_speed(void);

// Physical controller switching & assignment (DmGamepad.m)
bool dm_pad_get_merge(void);
void dm_pad_set_merge(bool merge);
bool dm_pad_get_press_to_join(void);
void dm_pad_reclaim_order(void);   // clear all slots and let controllers claim 1P, 2P... by pressing any button
int dm_pad_connected_count(void);
const char *dm_pad_connected_name(int index);
int dm_pad_connected_player(int index);   // 1-based player index (1..DM_PLAYERS), 0 if waiting/unassigned, 1 if merged
void dm_pad_set_as_p1(int index);         // promote connected controller at index to player 1 (swapping with current P1 if any)
#ifdef __cplusplus
}
#endif
