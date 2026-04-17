#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __GNUC__
#define LW_API __attribute__((visibility("default")))
#else
#define LW_API
#endif

LW_API void* lw_renderer_create();
LW_API void* lw_renderer_create_with_assets(const char* assetsPath);
LW_API void lw_renderer_load(void* renderer, const char* wallpaperPath, int width, int height);
LW_API void lw_renderer_set_assets_path(void* renderer, const char* assetsPath);
LW_API void lw_renderer_tick(void* renderer);
LW_API void lw_renderer_resize(void* renderer, int width, int height);
LW_API void lw_renderer_set_mouse(void* renderer, double x, double y, int clicked);
LW_API void lw_renderer_set_property(void* renderer, const char* name, const char* value);
LW_API void lw_renderer_show_window(void* renderer);
LW_API void lw_renderer_hide_window(void* renderer);
LW_API void lw_renderer_set_desktop_window(void* renderer, int desktop);
LW_API int lw_renderer_close_requested(void* renderer);
LW_API unsigned int lw_renderer_get_texture(void* renderer);
LW_API int lw_renderer_get_width(void* renderer);
LW_API int lw_renderer_get_height(void* renderer);
LW_API int lw_renderer_capture_frame(void* renderer, unsigned char** outBuffer, int* outWidth, int* outHeight);
LW_API void lw_renderer_free_buffer(void* buffer);
LW_API void lw_renderer_set_screen(void* renderer, int screenIndex);
LW_API void lw_renderer_destroy(void* renderer);

#ifdef __cplusplus
}
#endif
