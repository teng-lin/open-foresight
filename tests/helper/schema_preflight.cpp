#include "schema_preflight.h"
#include <iostream>
int main(int argc, char **argv) {
  if (argc < 2 || argc > 3)
    return 2;
  try {
    auto source = foresight::schema::qualify_helpers(argv[1]);
    if (argc == 3 && std::string(argv[2]) == "--wait") {
      std::cout << "qualified\n" << std::flush;
      std::string ignored;
      std::getline(std::cin, ignored);
    }
    source.verify_unchanged();
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
