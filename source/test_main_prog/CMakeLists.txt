set(CMAKE_CXX_STANDARD 14)

add_library(cuda_visualize visualize.cu)
################################################################
# Configuration for main_image
################################################################
add_executable(main_image image.cpp)
target_link_libraries(main_image
        cuda_flooding
        cuda_ms_filter
        cuda_union_find
        cuda_visualize
        m pthread X11
        ${CUDA_LIBRARIES})
target_include_directories(main_image PRIVATE ${CMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES})

################################################################
# Configuration for main_camera
################################################################
if (OpenCV_FOUND)
    add_executable(main_camera camera.cpp)
    target_link_libraries(main_camera
        cuda_flooding
        cuda_ms_filter
        cuda_union_find
        cuda_visualize
        m pthread X11
        ${OpenCV_LIBS}
        ${CUDA_LIBRARIES})
    target_include_directories(main_camera PRIVATE ${CMAKE_CUDA_TOOLKIT_INCLUDE_DIRECTORIES})
endif ()