/*
 * asan_options.c — bake detect_leaks=0 into the my_basic fuzz binary.
 *
 * Mayhem owns the runtime ASAN_OPTIONS (abort_on_error=1, symbolize=0, …) and sets
 * them via the environment. It does NOT set detect_leaks, which defaults to 1 on
 * supported platforms. LeakSanitizer (LSan) requires /proc/self/mem write access and
 * fails fatally when the process is traced (e.g. under Mayhem's ptrace-based coverage
 * collector), causing every run to exit 1 → 0 edges.
 *
 * The fix: define __asan_default_options() as a weak symbol compiled into the binary.
 * Options in __asan_default_options fill in any gaps not covered by the runtime
 * ASAN_OPTIONS env var, so detect_leaks=0 takes effect before LSan initialises and
 * before Mayhem's tracer attaches. This completely disables LSan while leaving full
 * ASan + UBSan memory/UB error detection in place.
 *
 * Reference: same pattern as mayhemheroes/wasmedge harness.
 */

__attribute__((weak)) const char *__asan_default_options(void) {
    return "detect_leaks=0";
}
