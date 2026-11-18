# Source from a firmware wrapper after it sets repo to the repository path.
if [ -z "${IDF_PATH:-}" ] && [ -d "$HOME/.platformio/packages/framework-espidf" ] &&
   [ -x "$repo/.cache/idf-python/bin/python" ]; then
  vault_idf_packages="$HOME/.platformio/packages"
  export IDF_PATH="$vault_idf_packages/framework-espidf"
  export IDF_TOOLS_PATH="$repo/.cache/idf-tools"
  export IDF_PYTHON_ENV_PATH="$repo/.cache/idf-python"
  export VAULT_IDF_PYTHON="$IDF_PYTHON_ENV_PATH/bin/python"
  export PATH="$vault_idf_packages/tool-cmake/bin:$vault_idf_packages/tool-ninja:$IDF_TOOLS_PATH/tools/xtensa-esp-elf/esp-15.2.0_20251204/xtensa-esp-elf/bin:$IDF_TOOLS_PATH/tools/riscv32-esp-elf/esp-15.2.0_20251204/riscv32-esp-elf/bin:$IDF_PYTHON_ENV_PATH/bin:$PATH"
fi
if [ -n "${IDF_PATH:-}" ]; then
  if [ -z "${ESP_ROM_ELF_DIR:-}" ] && [ -d "$HOME/.platformio/packages/tool-esp-rom-elfs" ]; then
    export ESP_ROM_ELF_DIR="$HOME/.platformio/packages/tool-esp-rom-elfs"
  fi
  export ESP_IDF_VERSION=6.0.0
  export IDF_COMPONENT_CACHE_PATH="${IDF_COMPONENT_CACHE_PATH:-$repo/.cache/idf-components}"
fi
