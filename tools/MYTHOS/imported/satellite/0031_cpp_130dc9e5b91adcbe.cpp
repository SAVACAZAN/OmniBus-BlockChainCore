// double_free_exploit.cpp
// Double free pattern
#include <cstdlib>

void double_free_exploit() {
    void *ptr = malloc(64);
    free(ptr);