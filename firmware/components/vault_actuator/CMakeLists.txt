set(sources
    vault_actuator.cpp
    vault_journal.cpp
    vault_generation_store.cpp
    calibration_knob.cpp
    vault_box_device.cpp
    feedback.cpp
    box_service.cpp
    box_service_storage.cpp
    box_service_wire.cpp
)
if(COMMAND idf_component_register)
    idf_component_register(SRCS ${sources} INCLUDE_DIRS include REQUIRES vault_device)
    set(vault_actuator_target ${COMPONENT_LIB})
else()
    add_library(vault_actuator STATIC ${sources})
    target_include_directories(vault_actuator PUBLIC include)
    target_link_libraries(vault_actuator PUBLIC vault_device)
    add_executable(calibration_knob_runner "${CMAKE_CURRENT_LIST_DIR}/../../../tools/firmware/calibration_knob_runner.cpp")
    target_link_libraries(calibration_knob_runner PRIVATE vault_actuator)
    set_target_properties(calibration_knob_runner PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
    set(vault_actuator_target vault_actuator)
endif()
target_compile_features(${vault_actuator_target} PUBLIC cxx_std_17)
target_compile_options(${vault_actuator_target} PRIVATE -fno-exceptions -fno-rtti)
