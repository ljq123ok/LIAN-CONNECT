cmake_minimum_required(VERSION 3.16)
project(lianbridge)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()
set(LIBS_DIR ${NATIVE_ROOT}/../../../libs/${OHOS_ARCH})

add_library(lianbridge SHARED napi_init.cpp)

# The Go core is packaged alongside the NAPI bridge and loaded at runtime via
# dlopen. It intentionally has no link-time dependency on the bridge.
target_link_libraries(lianbridge PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so)
