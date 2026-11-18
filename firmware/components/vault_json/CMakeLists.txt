set(yyjson_dir "${CMAKE_CURRENT_LIST_DIR}/../../third_party/yyjson")
set(sources vault_json.cpp json_number.cpp json_writer.cpp "${yyjson_dir}/yyjson.c")

if(COMMAND idf_component_register)
    idf_component_register(SRCS ${sources} INCLUDE_DIRS include PRIV_INCLUDE_DIRS "${yyjson_dir}")
    set(vault_json_target ${COMPONENT_LIB})
else()
    add_library(vault_json STATIC ${sources})
    target_include_directories(vault_json PUBLIC include PRIVATE "${yyjson_dir}")
    set(vault_json_target vault_json)
endif()

target_compile_features(${vault_json_target} PUBLIC cxx_std_17 PRIVATE c_std_99)
target_compile_definitions(${vault_json_target} PRIVATE
    YYJSON_DISABLE_FILE=1 YYJSON_DISABLE_UTILS=1 YYJSON_DISABLE_NON_STANDARD=1
    YYJSON_VAULT_FIXED_ARENA=1)
target_compile_options(${vault_json_target} PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions;-fno-rtti>")
