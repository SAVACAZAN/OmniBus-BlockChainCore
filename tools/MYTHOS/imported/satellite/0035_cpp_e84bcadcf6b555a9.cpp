};

void vtable_hijack_exploit(Victim *v) {
    // Scrie peste vtable pointer (dacă buffer overflow)
    // uintptr_t *vtable_ptr = reinterpret_cast<uintptr_t*>(v);
    // *vtable_ptr = fake_vtable;
    // Nu se poate executa direct - doar pattern
}