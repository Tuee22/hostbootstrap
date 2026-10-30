#if defined(_WIN32) && (defined(__x86_64__) || defined(__i386__))
#include <cpuid.h>
#endif

/* -1 is an unsupported observation, never an absent hypervisor. */
int hostbootstrap_wsl_hypervisor_present(void)
{
#if defined(_WIN32) && (defined(__x86_64__) || defined(__i386__))
    unsigned int eax, ebx, ecx, edx;
    if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) {
        return -1;
    }
    return (ecx & (1u << 31)) != 0;
#else
    return -1;
#endif
}
