#include <stdlib.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // Set before any thread exists, since setenv is not safe against a concurrent getenv.
  setenv("SLIMM_SHARE_AUDIO_SOURCE", "slimm-share-mix.monitor", 1);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
