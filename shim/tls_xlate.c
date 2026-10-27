/* Android <29 ignores AArch64 TLSDESC relocations. Repair only the two Copilot
 * addons' local descriptors before their constructors, using compiler-rt's
 * emutls allocator and thread-exit cleanup rather than Android TLS internals.
 *
 * Each addon needs its own copy of this dependency so its constructor runs
 * even when the other addon has already been loaded. No exported interposers.
 */
#define _GNU_SOURCE
#include <elf.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if !defined(__aarch64__)
#error "The TLS descriptor bridge supports AArch64 only"
#endif

/* compiler-rt emutls ABI, also used by clang -femulated-tls. */
struct emutls_control {
    uintptr_t size, align, index;
    void *initial;
};
extern void *__emutls_get_address(struct emutls_control *);
struct tls_arg {
    struct emutls_control *control;
    uintptr_t offset;
};
struct tls_desc {
    uintptr_t (*resolver)(struct tls_desc *);
    struct tls_arg *arg;
};
extern uintptr_t copilot_tlsdesc(struct tls_desc *);

__attribute__((visibility("hidden")))
uintptr_t copilot_tls_address(struct tls_desc *desc) {
    uintptr_t address = (uintptr_t)__emutls_get_address(desc->arg->control);
    return address + desc->arg->offset - (uintptr_t)__builtin_thread_pointer();
}

/* TLSDESC is not an ordinary AAPCS call: preserve all registers except x0,
 * including SIMD registers and flags, across compiler-rt's C implementation. */
__asm__(
    ".text\n.hidden copilot_tlsdesc\n.global copilot_tlsdesc\n"
    ".type copilot_tlsdesc,%function\ncopilot_tlsdesc:\n"
    "sub sp, sp, #672\n"
    "stp x1, x2, [sp, #0]\nstp x3, x4, [sp, #16]\n"
    "stp x5, x6, [sp, #32]\nstp x7, x8, [sp, #48]\n"
    "stp x9, x10, [sp, #64]\nstp x11, x12, [sp, #80]\n"
    "stp x13, x14, [sp, #96]\nstp x15, x16, [sp, #112]\n"
    "stp x17, x18, [sp, #128]\nstr x30, [sp, #144]\n"
    "mrs x1, nzcv\nstr x1, [sp, #152]\n"
    "stp q0, q1, [sp, #160]\nstp q2, q3, [sp, #192]\n"
    "stp q4, q5, [sp, #224]\nstp q6, q7, [sp, #256]\n"
    "stp q8, q9, [sp, #288]\nstp q10, q11, [sp, #320]\n"
    "stp q12, q13, [sp, #352]\nstp q14, q15, [sp, #384]\n"
    "stp q16, q17, [sp, #416]\nstp q18, q19, [sp, #448]\n"
    "stp q20, q21, [sp, #480]\nstp q22, q23, [sp, #512]\n"
    "stp q24, q25, [sp, #544]\nstp q26, q27, [sp, #576]\n"
    "stp q28, q29, [sp, #608]\nstp q30, q31, [sp, #640]\n"
    "bl copilot_tls_address\n"
    "ldp q0, q1, [sp, #160]\nldp q2, q3, [sp, #192]\n"
    "ldp q4, q5, [sp, #224]\nldp q6, q7, [sp, #256]\n"
    "ldp q8, q9, [sp, #288]\nldp q10, q11, [sp, #320]\n"
    "ldp q12, q13, [sp, #352]\nldp q14, q15, [sp, #384]\n"
    "ldp q16, q17, [sp, #416]\nldp q18, q19, [sp, #448]\n"
    "ldp q20, q21, [sp, #480]\nldp q22, q23, [sp, #512]\n"
    "ldp q24, q25, [sp, #544]\nldp q26, q27, [sp, #576]\n"
    "ldp q28, q29, [sp, #608]\nldp q30, q31, [sp, #640]\n"
    "ldr x1, [sp, #152]\nmsr nzcv, x1\n"
    "ldp x1, x2, [sp, #0]\nldp x3, x4, [sp, #16]\n"
    "ldp x5, x6, [sp, #32]\nldp x7, x8, [sp, #48]\n"
    "ldp x9, x10, [sp, #64]\nldp x11, x12, [sp, #80]\n"
    "ldp x13, x14, [sp, #96]\nldp x15, x16, [sp, #112]\n"
    "ldp x17, x18, [sp, #128]\nldr x30, [sp, #144]\n"
    "add sp, sp, #672\nret\n.size copilot_tlsdesc,.-copilot_tlsdesc\n"
);

static void fail(const char *name, const char *reason) {
    fprintf(stderr, "[tls_xlate] ERROR: %s: %s\n", name, reason);
    abort();
}

static int descriptor_protection(const struct dl_phdr_info *info, uintptr_t address,
                                 size_t size) {
    int prot = -1;
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        uintptr_t start = info->dlpi_addr + p->p_vaddr;
        if (p->p_type == PT_LOAD && address >= start &&
            address + size <= start + p->p_memsz) {
            prot = ((p->p_flags & PF_R) ? PROT_READ : 0) |
                   ((p->p_flags & PF_W) ? PROT_WRITE : 0) |
                   ((p->p_flags & PF_X) ? PROT_EXEC : 0);
            break;
        }
    }
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        uintptr_t start = info->dlpi_addr + p->p_vaddr;
        if (p->p_type == PT_GNU_RELRO && address >= start &&
            address + size <= start + p->p_memsz) prot &= ~PROT_WRITE;
    }
    return prot;
}

static int repair_tls(struct dl_phdr_info *info, size_t size, void *unused) {
    (void)size;
    (void)unused;
    const char *name = strrchr(info->dlpi_name, '/');
    name = name ? name + 1 : info->dlpi_name;
    if (strcmp(name, "cli-native.node") && strcmp(name, "runtime.node")) return 0;
    const ElfW(Phdr) *tls = NULL;
    const ElfW(Dyn) *dynamic = NULL;
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        if (p->p_type == PT_TLS) tls = p;
        if (p->p_type == PT_DYNAMIC)
            dynamic = (const ElfW(Dyn) *)(info->dlpi_addr + p->p_vaddr);
    }
    if (!tls || !dynamic) return 0;
    const ElfW(Rela) *relocations = NULL;
    size_t bytes = 0, entry_size = 0;
    for (; dynamic->d_tag != DT_NULL; ++dynamic) {
        if (dynamic->d_tag == DT_RELA)
            relocations = (const ElfW(Rela) *)(info->dlpi_addr + dynamic->d_un.d_ptr);
        if (dynamic->d_tag == DT_RELASZ) bytes = dynamic->d_un.d_val;
        if (dynamic->d_tag == DT_RELAENT) entry_size = dynamic->d_un.d_val;
    }
    if (!relocations || entry_size != sizeof(*relocations))
        fail(name, "unsupported TLS relocation table");
    if (tls->p_filesz > tls->p_memsz) fail(name, "invalid TLS template");
    struct emutls_control *control = NULL;
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    for (size_t i = 0; i < bytes / sizeof(*relocations); ++i) {
        const ElfW(Rela) *r = &relocations[i];
        unsigned type = ELF64_R_TYPE(r->r_info);
        if (type >= R_AARCH64_TLS_DTPMOD && type <= R_AARCH64_TLS_TPREL)
            fail(name, "only local TLSDESC relocations are supported");
        if (type != R_AARCH64_TLSDESC) continue;
        struct tls_desc *desc = (struct tls_desc *)(info->dlpi_addr + r->r_offset);
        int prot = descriptor_protection(info, (uintptr_t)desc, sizeof(*desc));
        if (prot < 0 || !(prot & PROT_READ) || (prot & PROT_EXEC))
            fail(name, "descriptor is outside readable data");
        if (desc->resolver) continue; /* Native loader or an earlier bridge owns it. */
        if (ELF64_R_SYM(r->r_info) || r->r_addend < 0 ||
            (uintptr_t)r->r_addend >= tls->p_memsz)
            fail(name, "unsupported nonlocal TLS descriptor");
        if (!control) {
            control = calloc(1, sizeof(*control));
            if (!control) fail(name, "cannot allocate TLS control");
            control->size = tls->p_memsz;
            control->align = tls->p_align > sizeof(void *) ? tls->p_align : sizeof(void *);
            control->initial = calloc(1, control->size);
            if (!control->initial) fail(name, "cannot allocate TLS template");
            memcpy(control->initial, (void *)(info->dlpi_addr + tls->p_vaddr), tls->p_filesz);
        }
        struct tls_arg *arg = malloc(sizeof(*arg));
        if (!arg) fail(name, "cannot allocate TLS descriptor");
        arg->control = control;
        arg->offset = r->r_addend;
        uintptr_t start = (uintptr_t)desc & ~(page - 1);
        if ((uintptr_t)desc + sizeof(*desc) > start + page)
            fail(name, "cross-page TLS descriptor is unsupported");
        if (mprotect((void *)start, page, prot | PROT_WRITE))
            fail(name, "cannot update TLS descriptor");
        desc->arg = arg;
        desc->resolver = copilot_tlsdesc;
        if (mprotect((void *)start, page, prot))
            fail(name, "cannot restore TLS descriptor protection");
    }
    return 0;
}

__attribute__((constructor))
static void initialize_tls_bridge(void) {
    dl_iterate_phdr(repair_tls, NULL);
}
