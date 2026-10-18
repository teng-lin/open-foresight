// Acceptance-only Wayland keyboard with a normal US keymap. wtype's compact
// generated keymap does not match this compositor's physical keybind mapping.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

static uint32_t timestamp(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint32_t)((uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

static const struct wl_interface keyboard_interface;
static const struct wl_interface *create_types[] = {&wl_seat_interface,
                                                    &keyboard_interface};
static const struct wl_message manager_methods[] = {
    {"create_virtual_keyboard", "on", create_types}};
static const struct wl_interface manager_interface = {
    "zwp_virtual_keyboard_manager_v1", 1, 1, manager_methods, 0, NULL};
static const struct wl_message keyboard_methods[] = {
    {"keymap", "uhu", NULL},
    {"key", "uuu", NULL},
    {"modifiers", "uuuu", NULL},
    {"destroy", "", NULL}};
static const struct wl_interface keyboard_interface = {
    "zwp_virtual_keyboard_v1", 1, 4, keyboard_methods, 0, NULL};
static struct wl_proxy *manager;
static struct wl_seat *seat;
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
  if (!strcmp(interface, manager_interface.name))
    manager = wl_registry_bind(registry, name, &manager_interface, 1);
  if (!strcmp(interface, "wl_seat") && !seat)
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {}
int main(void) {
  struct wl_display *display = wl_display_connect(NULL);
  if (!display)
    return 1;
  struct wl_registry *registry = wl_display_get_registry(display);
  const struct wl_registry_listener listener = {global, removed};
  wl_registry_add_listener(registry, &listener, NULL);
  if (wl_display_roundtrip(display) < 0)
    return 5;
  if (!manager || !seat) {
    fprintf(stderr, "Virtual keyboard protocol unavailable\n");
    return 2;
  }
  struct wl_proxy *keyboard =
      wl_proxy_marshal_flags(manager, 0, &keyboard_interface, 1, 0, seat, NULL);
  struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_rule_names names = {.layout = "us"};
  struct xkb_keymap *keymap =
      xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t size = strlen(text) + 1;
  int fd = memfd_create("foresight-test-keymap", MFD_CLOEXEC);
  if (fd < 0 || ftruncate(fd, size))
    return 3;
  if (write(fd, text, size) != (ssize_t)size)
    return 4;
  wl_proxy_marshal_flags(keyboard, 0, NULL, 1, 0, 1, fd, (uint32_t)size);
  if (wl_display_roundtrip(display) < 0)
    return 5;
  uint32_t mask = (1u << xkb_keymap_mod_get_index(keymap, XKB_MOD_NAME_CTRL)) |
                  (1u << xkb_keymap_mod_get_index(keymap, XKB_MOD_NAME_SHIFT));
  wl_proxy_marshal_flags(keyboard, 2, NULL, 1, 0, mask, 0u, 0u, 0u);
  if (wl_display_roundtrip(display) < 0)
    return 5;
  wl_proxy_marshal_flags(keyboard, 1, NULL, 1, 0, timestamp(), 33u,
                         1u); // evdev KEY_F
  if (wl_display_roundtrip(display) < 0)
    return 5;
  usleep(100000);
  wl_proxy_marshal_flags(keyboard, 1, NULL, 1, 0, timestamp(), 33u, 0u);
  wl_proxy_marshal_flags(keyboard, 2, NULL, 1, 0, 0u, 0u, 0u, 0u);
  if (wl_display_roundtrip(display) < 0)
    return 5;
  wl_proxy_marshal_flags(keyboard, 3, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
  if (wl_display_roundtrip(display) < 0)
    return 5;
  close(fd);
  free(text);
  xkb_keymap_unref(keymap);
  xkb_context_unref(context);
  wl_proxy_destroy(manager);
  wl_seat_destroy(seat);
  wl_registry_destroy(registry);
  wl_display_disconnect(display);
  return 0;
}
