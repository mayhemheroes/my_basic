/*
 * asan_options.c — bake detect_leaks=0 into the my_basic fuzz binary.
 *
 * Mayhem owns the runtime ASAN_OPTIONS (abort_on_error=1, symbolize=0, …) and sets
 * them via the environment. It does NOT set detect_leaks, which defaults to 1 on
 * supported platforms. LeakSanitizer (LSan) requires /proc/self/mem write access and
 * fails fatally when the process is traced (e.g. under Mayhem's ptrace-based coverage
 * collector), causing every run to exit 1 → 0 edges.
 *
 * The fix: define __asan_default_options() as a STRONG symbol compiled into the binary.
 * The ASan static runtime already ships its own WEAK default definition, and when the
 * user definition is also weak the linker keeps the runtime's copy — so a weak
 * definition here never takes effect and LSan stays enabled (verified under strace:
 * weak → "LeakSanitizer does not work under ptrace", exit 1 on every input; strong →
 * exit 0). The strong definition overrides the runtime's weak one, so detect_leaks=0
 * takes effect before LSan initialises and before Mayhem's tracer attaches. This
 * completely disables LSan while leaving full ASan + UBSan error detection in place.
 */

const char *__asan_default_options(void) {
    return "detect_leaks=0";
}
