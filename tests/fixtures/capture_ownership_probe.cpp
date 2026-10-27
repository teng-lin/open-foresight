#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 4)
    return 20;
  // NOLOAD proves dyld inserted the fixture before main, as in the service.
  if (!dlopen(argv[1], RTLD_NOLOAD | RTLD_NOW)) {
    std::fputs("capture fixture was not inserted before main\n", stderr);
    return 21;
  }
  if (std::getenv("DYLD_INSERT_LIBRARIES")) {
    std::fputs("capture fixture left descendant injection armed\n", stderr);
    return 22;
  }
  // Inherit the constructor's actual environment, without a copied override.
  execv(argv[2], argv + 2);
  std::perror("ownership utility exec");
  return 23;
}
