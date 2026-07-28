#include "my_application.h"

#include <cstdlib>

int main(int argc, char** argv) {
  // Run via XWayland even on Wayland sessions: GNOME's Wayland compositor
  // ignores keep-above for native Wayland windows, but honors it for X11
  // clients. The encoder window must stay frontmost (project rule) so the
  // displayed cimbar barcode is never occluded. Users can still override
  // by exporting GDK_BACKEND themselves (setenv with overwrite=0).
  setenv("GDK_BACKEND", "x11", 0);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
