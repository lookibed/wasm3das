# Big test: a standalone AOT context whose required module owns initialized
# globals generates, compiles, links and reads those globals back.

set(STANDALONE_MODULE_GLOBAL_GEN "${CMAKE_CURRENT_BINARY_DIR}/_generated")
file(MAKE_DIRECTORY "${STANDALONE_MODULE_GLOBAL_GEN}")

add_custom_command(
    OUTPUT "${STANDALONE_MODULE_GLOBAL_GEN}/standalone_module_global_fixture.das.cpp"
           "${STANDALONE_MODULE_GLOBAL_GEN}/standalone_module_global_fixture.das.h"
    COMMAND $<TARGET_FILE:daslang>
        "${PROJECT_SOURCE_DIR}/utils/aot/main.das"
        -- -ctx "${CMAKE_CURRENT_SOURCE_DIR}/standalone_module_global_fixture.das"
        "${STANDALONE_MODULE_GLOBAL_GEN}/"
    DEPENDS daslang
        "${CMAKE_CURRENT_SOURCE_DIR}/standalone_module_global_fixture.das"
        "${CMAKE_CURRENT_SOURCE_DIR}/standalone_module_global_dep.das"
        "${PROJECT_SOURCE_DIR}/utils/aot/main.das"
        "${PROJECT_SOURCE_DIR}/daslib/aot_standalone.das"
        "${PROJECT_SOURCE_DIR}/daslib/aot_cpp.das"
    WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
    COMMENT "Standalone AOT: standalone_module_global_fixture.das"
    VERBATIM
)

add_executable(test_standalone_module_global
    test_standalone_module_global.cpp
    "${STANDALONE_MODULE_GLOBAL_GEN}/standalone_module_global_fixture.das.cpp")
target_link_libraries(test_standalone_module_global PRIVATE
    libDaScript ${SRC_LIBRARIES} ${DAS_MODULES_LIBS})
target_include_directories(test_standalone_module_global PRIVATE "${STANDALONE_MODULE_GLOBAL_GEN}" ${NEED_MODULES_PATH})
SETUP_CPP11(test_standalone_module_global)
set_target_properties(test_standalone_module_global PROPERTIES FOLDER "tests-cpp/big")

add_test(NAME standalone_module_global COMMAND test_standalone_module_global
         WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})
set_tests_properties(standalone_module_global PROPERTIES LABELS "big")
add_dependencies(test-big test_standalone_module_global)
