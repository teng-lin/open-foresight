cmake_minimum_required(VERSION 3.22)
# Match the native build's source/binary paths and directory defaults. Dependency
# projects retain their own settings (including SentencePiece's C++17 override).
project(open_foresight LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(cmake/ForesightInferenceDependencies.cmake)
